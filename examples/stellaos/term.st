// Terminal: the shell in a window. It shows the console (everything printed, with its colors and
// cursor movements: a small ANSI terminal) and types the window's keys into it, as if they came over
// the serial line. There is one console, so there is one terminal.

import kernel
import gfx
import input
import wm

extern fn st_k_console_capture(on: bool)
extern fn st_k_console_take() -> str
extern fn st_k_inject(b: int)
extern fn st_ord(s: str) -> int

const BG = 0x16141f
const FG = 0xdcdae6
const PALETTE = [0x2b2838, 0xff6b81, 0x7bed9f, 0xfdcb6e, 0x74b9ff, 0xc39bff, 0x63e6e2, 0xdcdae6]
const BRIGHT = [0x5e5a72, 0xff8fa3, 0xa3f7bf, 0xffe08a, 0xa0d2ff, 0xdcc2ff, 0x9df3ef, 0xffffff]
const SCROLLBACK = 400

struct Cell {
    ch: str = " ",
    fg: int = FG,
    bold: bool = false,
}

struct Term {
    lines: [[Cell]] = [[]],   // the scrollback and the screen; the cursor is on the last screen
    row: int = 0,             // cursor, in `lines`
    col: int = 0,
    fg: int = FG,
    bold: bool = false,
    dim: bool = false,
    esc: str = "",            // an escape sequence being read
    cols: int = 80,
    rows: int = 24,
    back: int = 0,            // lines scrolled back by the wheel
    changed: bool = true,

    fn feed(self, s: str) {
        if s == "" { return }
        self.changed = true
        self.back = 0
        for c in s.chars() { self.put(c) }
    }

    fn put(self, c: str) {
        if self.esc != "" {
            self.esc += c
            if self.esc == "${kernel.ESC}[" { return }
            if self.esc.len() > 1 && self.esc.slice(0, 2) != "${kernel.ESC}[" {
                self.esc = ""
                return
            }
            let code = st_ord(c)
            if code >= 64 && code <= 126 {   // the final byte
                self.csi(self.esc.slice(2, self.esc.len() - 1), c)
                self.esc = ""
            }
            return
        }
        if c == kernel.ESC {
            self.esc = c
        } else if c == "\n" {
            self.newline()
        } else if c == "\r" {
            self.col = 0
        } else if st_ord(c) == 8 {
            self.col = max(self.col - 1, 0)
        } else if c == "\t" {
            self.col = (self.col / 8 + 1) * 8
        } else if st_ord(c) >= 32 {
            if self.col >= self.cols {
                self.newline()
            }
            let line = self.lines[self.row]
            while line.len() <= self.col { line.push(Cell {}) }
            line[self.col] = Cell { ch: c, fg: if self.dim { gfx.mix(self.fg, BG, 2, 5) } else { self.fg }, bold: self.bold }
            self.col += 1
        }
    }

    fn newline(self) {
        self.col = 0
        self.row += 1
        if self.row >= self.lines.len() { self.lines.push([]) }
        if self.lines.len() > SCROLLBACK {
            self.lines.remove(0)
            self.row -= 1
        }
    }

    // ESC [ params final
    fn csi(self, params: str, final: str) {
        let ps = params.split(";").map(p => int(p) catch 0)
        let n = max(ps[0], 1)
        if final == "m" {
            for p in ps {
                if p == 0 {
                    self.fg = FG
                    self.bold = false
                    self.dim = false
                } else if p == 1 {
                    self.bold = true
                } else if p == 2 {
                    self.dim = true
                } else if p == 22 {
                    self.bold = false
                    self.dim = false
                } else if p >= 30 && p <= 37 {
                    self.fg = if self.bold { BRIGHT[p - 30] } else { PALETTE[p - 30] }
                } else if p >= 90 && p <= 97 {
                    self.fg = BRIGHT[p - 90]
                } else if p == 39 {
                    self.fg = FG
                }
            }
        } else if final == "K" {
            // erase to the end of the line
            let line = self.lines[self.row]
            while line.len() > self.col { line.pop() }
        } else if final == "J" {
            if ps[0] == 2 {
                // clear: a fresh screen below the scrollback
                for i in 0..self.rows { self.lines.push([]) }
                self.row = self.lines.len() - self.rows
                self.col = 0
                while self.lines.len() > SCROLLBACK {
                    self.lines.remove(0)
                    self.row -= 1
                }
            }
        } else if final == "H" {
            let top = max(self.lines.len() - self.rows, 0)
            self.row = min(top + max(ps[0], 1) - 1, self.lines.len() - 1)
            self.col = if ps.len() > 1 { max(ps[1], 1) - 1 } else { 0 }
        } else if final == "D" {
            self.col = max(self.col - n, 0)
        } else if final == "C" {
            self.col = min(self.col + n, self.cols - 1)
        } else if final == "A" {
            self.row = max(self.row - n, 0)
        } else if final == "B" {
            self.row = min(self.row + n, self.lines.len() - 1)
        }
    }

    fn paint(self, s: gfx.Surface) {
        let cw = gfx.text_width("M", gfx.MONO)
        let lh = gfx.line_height(gfx.MONO) + 2
        self.cols = max((s.width - 16) / cw, 10)
        self.rows = max((s.height - 12) / lh, 4)
        s.clear(BG)
        let last = max(self.row + 1, self.lines.len())
        let top = max(last - self.rows - self.back, 0)
        for r in 0..self.rows {
            let i = top + r
            if i >= self.lines.len() { break }
            let line = self.lines[i]
            let y = 6 + r * lh
            // runs of one style, drawn together
            var k = 0
            while k < line.len() {
                let start = k
                var run: [str] = []
                while k < line.len() && line[k].fg == line[start].fg && line[k].bold == line[start].bold {
                    run.push(line[k].ch)
                    k += 1
                }
                s.text(8 + start * cw, y, run.join(""), line[start].fg, if line[start].bold { gfx.MONO_BOLD } else { gfx.MONO })
            }
            if i == self.row && self.back == 0 {
                s.shade(8 + self.col * cw, y, cw, lh - 1, 0xc39bff, 170)
            }
        }
        if self.back > 0 {
            let label = "↑ ${self.back} lines back"
            let w = gfx.text_width(label, gfx.UI)
            s.round_shade(s.width - w - 24, 8, w + 16, 22, 6, 0xffffff, 40)
            s.text(s.width - w - 16, 11, label, 0xffffff, gfx.UI)
        }
    }

    fn key(self, e: input.Event) {
        if !e.down { return }
        let k = e.key
        if e.ctrl && k.len() == 1 {
            let c = st_ord(k.upper())
            if c >= 64 && c < 96 { st_k_inject(c - 64) }
            return
        }
        if k == "Enter" { st_k_inject(13) }
        else if k == "Backspace" { st_k_inject(127) }
        else if k == "Tab" { st_k_inject(9) }
        else if k == "Escape" { st_k_inject(27) }
        else if k == "ArrowUp" { inject("${kernel.ESC}[A") }
        else if k == "ArrowDown" { inject("${kernel.ESC}[B") }
        else if k == "ArrowRight" { inject("${kernel.ESC}[C") }
        else if k == "ArrowLeft" { inject("${kernel.ESC}[D") }
        else if k == "Home" { inject("${kernel.ESC}[H") }
        else if k == "End" { inject("${kernel.ESC}[F") }
        else if k == "Delete" { inject("${kernel.ESC}[3~") }
        else if e.text != "" { inject(e.text) }
        self.back = 0
    }
}

// type a string: its UTF-8 bytes
fn inject(s: str) {
    for c in s.chars() {
        let cp = st_ord(c)
        if cp < 0x80 {
            st_k_inject(cp)
        } else if cp < 0x800 {
            st_k_inject(0xc0 | (cp >> 6))
            st_k_inject(0x80 | (cp & 63))
        } else if cp < 0x10000 {
            st_k_inject(0xe0 | (cp >> 12))
            st_k_inject(0x80 | (cp >> 6 & 63))
            st_k_inject(0x80 | (cp & 63))
        } else {
            st_k_inject(0xf0 | (cp >> 18))
            st_k_inject(0x80 | (cp >> 12 & 63))
            st_k_inject(0x80 | (cp >> 6 & 63))
            st_k_inject(0x80 | (cp & 63))
        }
    }
}

// The terminal's program for a window.
fn app() -> wm.App {
    let t = Term {}
    st_k_console_capture(true)
    st_k_inject(13)       // an empty line: the shell answers with a fresh prompt
    return wm.App {
        tick: (k: wm.Tick) => {
            t.feed(st_k_console_take())
            let c = t.changed
            t.changed = false
            return c
        },
        paint: (s: gfx.Surface) => t.paint(s),
        key: (e: input.Event) => {
            t.key(e)
        },
        mouse: (e: input.Event) => {
            if e.kind == "wheel" {
                t.back = min(max(t.back - e.delta * 3, 0), max(t.lines.len() - t.rows, 0))
                t.changed = true
            }
        },
        close: () => st_k_console_capture(false),
    }
}
