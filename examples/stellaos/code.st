// Code: StellaOS's programming environment. Write a program, press Run (F5): it is compiled right
// here (cc.st) to RISC-V machine code and runs as a process of its own (proc.st), its output and
// questions in the console below, its graphics in a window of its own. Compile errors point at
// their line; a crashing program ends alone, with a message.
//
// The editor: syntax colors, line numbers, selection (Shift + arrows or the mouse), copy/cut/paste
// (Ctrl-C/X/V), undo (Ctrl-Z), Ctrl-A, Ctrl-S saves, Ctrl-D duplicates a line, Ctrl-/ comments,
// Tab indents, Enter keeps the indentation, Ctrl-F finds (F3 again), Ctrl-G goes to a line, Ctrl-N
// new, Ctrl-O the file list.

import kernel
import gfx
import input
import wm
import ramfs
import proc
import cc
import progwin

const BG = 0x1e1f29
const GUTTER = 0x191a22
const BAR = 0x262836
const LINE_HL = 0x262836
const SEL = 0x3b4f7a
const TEXT = 0xdcdfe4
const DIM = 0x6b7089
const KEYWORD = 0xc792ea
const TYPE = 0xffcb6b
const STRING = 0xc3e88d
const NUMBER = 0xf78c6c
const COMMENT = 0x676e95
const BUILTIN = 0x82aaff
const ERROR = 0xff5370
const OK = 0x5fd7a7
const CONSOLE = 0x15161d

const BAR_H = 38
const STATUS_H = 22
const SIDE_W = 190

const KEYWORDS = ["fn", "struct", "enum", "const", "let", "var", "if", "else", "while", "for", "in", "return", "break", "continue", "match", "true", "false", "self"]
const TYPES = ["int", "bool", "str", "void", "float"]
const BUILTINS = ["print", "println", "input", "read_line", "sleep", "now_ms", "random", "exit", "max", "min", "abs",
    "parse_int", "is_number", "char", "window", "clear", "rect", "circle", "line", "text", "big_text", "mono_text",
    "text_width", "show", "key", "mouse_x", "mouse_y", "mouse_down", "beep", "note", "read_file", "write_file",
    "file_exists", "pid", "user", "rgb", "gc_count", "memory_used", "sin", "cos", "tan", "atan", "atan2",
    "exp", "log", "pow", "sqrt", "floor", "parse_float", "float", "int"]

// what the editor needs from the system
struct Env {
    fs: ramfs.RamFs,
    procs: proc.Procs,
    home: fn() -> str,
    user: fn() -> str,
    sys: fn() -> proc.Sys,            // the system calls' glue for a new process (files, sound, ...)
    can_write: fn(str) -> bool = (p: str) => true,
}

struct Snap {
    text: str,
    row: int,
    col: int,
}

struct Button {
    x: int,
    y: int,
    w: int,
    h: int,
    id: str,
}

struct Editor {
    d: wm.Desktop,
    env: Env,
    win: int = 0,
    lines: [str] = [""],
    row: int = 0,
    col: int = 0,
    want_x: int = -1,             // the column (in pixels) up/down try to keep
    arow: int = -1,               // the selection's other end (-1: no selection)
    acol: int = 0,
    top: int = 0,
    left: int = 0,                // horizontal scroll (pixels)
    path: str = "",
    dirty: bool = false,
    undo: [Snap] = [],
    redo: [Snap] = [],
    last_edit: int = 0,
    last_kind: str = "",
    sidebar: bool = true,
    side_dir: str = "",
    side_top: int = 0,
    console: [str] = [],
    con_partial: str = "",
    con_input: str = "",
    con_focus: bool = false,
    con_back: int = 0,
    err_line: int = 0,
    err_msg: str = "",
    status: str = "",
    p: proc.Proc? = none,
    changed: bool = true,
    buttons: [Button] = [],
    w: int = 760,
    h: int = 560,
    dragging: bool = false,
    cw: int = 8,                  // the monospace font's advance
    lh: int = 18,
    blink: int = 0,
    bar: str = "",                // "find" or "goto": the little bar at the editor's foot
    query: str = "",
    last_find: str = "",

    // ---- text ----

    fn text(self) -> str { return self.lines.join("\n") }

    fn set_text(self, t: str) {
        self.lines = t.split("\n")
        if self.lines.is_empty() { self.lines = [""] }
        self.row = 0
        self.col = 0
        self.arow = -1
        self.top = 0
        self.left = 0
        self.err_line = 0
    }

    fn line(self) -> str { return self.lines[self.row] }

    fn snapshot(self, kind: str) {
        let now = kernel.uptime()
        if kind != self.last_kind || now - self.last_edit > 1500 || kind == "" {
            self.undo.push(Snap { text: self.text(), row: self.row, col: self.col })
            if self.undo.len() > 200 { self.undo.remove(0) }
            self.redo = []
        }
        self.last_kind = kind
        self.last_edit = now
        self.dirty = true
        self.err_line = 0
    }

    fn restore(self, from: [Snap], to: [Snap]) {
        if from.is_empty() { return }
        to.push(Snap { text: self.text(), row: self.row, col: self.col })
        let s = from.pop()
        let r = s.row
        let c = s.col
        self.set_text(s.text)
        self.row = min(r, self.lines.len() - 1)
        self.col = min(c, self.line().len())
        self.last_kind = ""
        self.dirty = true
    }

    fn has_sel(self) -> bool { return self.arow >= 0 && (self.arow != self.row || self.acol != self.col) }

    // the selection's start and end, in order: [r0, c0, r1, c1]
    fn sel(self) -> [int] {
        if self.arow < self.row || (self.arow == self.row && self.acol < self.col) { return [self.arow, self.acol, self.row, self.col] }
        return [self.row, self.col, self.arow, self.acol]
    }

    fn sel_text(self) -> str {
        if !self.has_sel() { return "" }
        let s = self.sel()
        if s[0] == s[2] { return self.lines[s[0]].slice(s[1], s[3]) }
        var parts = [self.lines[s[0]].slice(s[1], self.lines[s[0]].len())]
        for r in s[0] + 1..s[2] { parts.push(self.lines[r]) }
        parts.push(self.lines[s[2]].slice(0, s[3]))
        return parts.join("\n")
    }

    fn delete_sel(self) {
        if !self.has_sel() {
            self.arow = -1
            return
        }
        let s = self.sel()
        let head = self.lines[s[0]].slice(0, s[1])
        let tail = self.lines[s[2]].slice(s[3], self.lines[s[2]].len())
        var keep: [str] = []
        for r in 0..s[0] { keep.push(self.lines[r]) }
        keep.push(head + tail)
        for r in s[2] + 1..self.lines.len() { keep.push(self.lines[r]) }
        self.lines = keep
        self.row = s[0]
        self.col = s[1]
        self.arow = -1
    }

    fn insert(self, t: str) {
        self.delete_sel()
        let l = self.line()
        let head = l.slice(0, self.col)
        let tail = l.slice(self.col, l.len())
        let parts = t.split("\n")
        if parts.len() == 1 {
            self.lines[self.row] = head + t + tail
            self.col += t.len()
            return
        }
        self.lines[self.row] = head + parts[0]
        for k in 1..parts.len() {
            self.lines.insert(self.row + k, parts[k])
        }
        self.row += parts.len() - 1
        self.col = self.lines[self.row].len()
        self.lines[self.row] = self.lines[self.row] + tail
    }

    fn indent_of(self, l: str) -> str {
        var n = 0
        while n < l.len() && l[n] == " " { n += 1 }
        return l.slice(0, n)
    }

    // ---- moving ----

    fn char_left(self, l: str, c: int) -> int {
        var k = c - 1
        while k > 0 && is_cont(l, k) { k -= 1 }
        return max(0, k)
    }
    fn char_right(self, l: str, c: int) -> int {
        var k = c + 1
        while k < l.len() && is_cont(l, k) { k += 1 }
        return min(l.len(), k)
    }

    fn x_of(self, r: int, c: int) -> int { return gfx.text_width(self.lines[r].slice(0, c), gfx.MONO) }

    fn col_at(self, r: int, x: int) -> int {
        let l = self.lines[r]
        var c = 0
        while c < l.len() {
            let n = self.char_right(l, c)
            let mid = (gfx.text_width(l.slice(0, c), gfx.MONO) + gfx.text_width(l.slice(0, n), gfx.MONO)) / 2
            if x < mid { return c }
            c = n
        }
        return l.len()
    }

    fn move_to(self, r: int, c: int, selecting: bool) {
        if selecting {
            if self.arow < 0 {
                self.arow = self.row
                self.acol = self.col
            }
        } else {
            self.arow = -1
        }
        self.row = max(0, min(r, self.lines.len() - 1))
        self.col = max(0, min(c, self.lines[self.row].len()))
        self.blink = kernel.uptime()
    }

    fn word_left(self) -> int {
        let l = self.line()
        var c = self.col
        while c > 0 && l[c - 1] == " " { c -= 1 }
        while c > 0 && is_word(l, c - 1) { c -= 1 }
        if c == self.col && c > 0 { c -= 1 }
        return c
    }
    fn word_right(self) -> int {
        let l = self.line()
        var c = self.col
        while c < l.len() && is_word(l, c) { c += 1 }
        while c < l.len() && l[c] == " " { c += 1 }
        if c == self.col && c < l.len() { c += 1 }
        return c
    }

    // ---- the view ----

    fn rows(self) -> int { return max(1, (self.edit_h() - 8) / self.lh) }
    fn edit_x(self) -> int { return if self.sidebar { SIDE_W } else { 0 } }
    fn console_h(self) -> int { return max(110, self.h / 4) }
    fn edit_h(self) -> int { return self.h - BAR_H - STATUS_H - self.console_h() }
    fn gutter_w(self) -> int { return 16 + gfx.text_width("${max(self.lines.len(), 99)}", gfx.MONO) }

    fn reveal(self) {
        let n = self.rows()
        if self.row < self.top { self.top = self.row }
        if self.row >= self.top + n { self.top = self.row - n + 1 }
        let x = self.x_of(self.row, self.col)
        let room = self.w - self.edit_x() - self.gutter_w() - 20
        if x < self.left { self.left = max(0, x - 40) }
        if x > self.left + room { self.left = x - room + 40 }
    }

    // ---- keys ----

    fn key(self, e: input.Event) {
        if !e.down { return }
        self.changed = true
        let k = e.key
        if k == "F5" || (e.ctrl && (k == "r" || k == "R")) {
            self.run()
            return
        }
        if k == "F6" || (e.ctrl && k == "q") {
            self.stop()
            return
        }
        if self.con_focus {
            self.console_key(e)
            return
        }
        if self.bar != "" {
            self.bar_key(e)
            return
        }
        if k == "F3" {
            self.find_next(self.last_find, true)
            return
        }
        let sh = e.shift
        if e.ctrl {
            let c = k.lower()
            if c == "s" { self.save() }
            else if c == "z" { self.restore(self.undo, self.redo) }
            else if c == "y" { self.restore(self.redo, self.undo) }
            else if c == "a" {
                self.arow = 0
                self.acol = 0
                self.row = self.lines.len() - 1
                self.col = self.line().len()
            } else if c == "c" || c == "x" {
                if self.has_sel() {
                    clipboard_set(self.sel_text())
                    if c == "x" {
                        self.snapshot("")
                        self.delete_sel()
                    }
                } else {
                    // no selection: the whole line
                    clipboard_set(self.line() + "\n")
                    if c == "x" {
                        self.snapshot("")
                        if self.lines.len() > 1 { self.lines.remove(self.row) } else { self.lines[0] = "" }
                        self.row = min(self.row, self.lines.len() - 1)
                        self.col = 0
                    }
                }
            } else if c == "v" {
                self.snapshot("")
                self.insert(clipboard_get())
            } else if c == "d" {
                self.snapshot("")
                self.lines.insert(self.row + 1, self.line())
                self.row += 1
            } else if c == "/" {
                self.snapshot("")
                self.toggle_comment()
            } else if c == "f" {
                self.bar = "find"
                self.query = if self.has_sel() && !self.sel_text().contains("\n") { self.sel_text() } else { self.last_find }
            } else if c == "g" {
                self.bar = "goto"
                self.query = ""
            } else if c == "n" {
                self.new_file()
            } else if c == "o" {
                self.sidebar = !self.sidebar
            } else if k == "ArrowLeft" {
                self.move_to(self.row, self.word_left(), sh)
            } else if k == "ArrowRight" {
                self.move_to(self.row, self.word_right(), sh)
            } else if k == "Home" {
                self.move_to(0, 0, sh)
            } else if k == "End" {
                self.move_to(self.lines.len() - 1, 1 << 30, sh)
            }
            self.reveal()
            return
        }
        if k == "ArrowLeft" {
            if self.has_sel() && !sh {
                let s = self.sel()
                self.move_to(s[0], s[1], false)
            } else if self.col > 0 {
                self.move_to(self.row, self.char_left(self.line(), self.col), sh)
            } else if self.row > 0 {
                self.move_to(self.row - 1, 1 << 30, sh)
            }
            self.want_x = -1
        } else if k == "ArrowRight" {
            if self.has_sel() && !sh {
                let s = self.sel()
                self.move_to(s[2], s[3], false)
            } else if self.col < self.line().len() {
                self.move_to(self.row, self.char_right(self.line(), self.col), sh)
            } else if self.row < self.lines.len() - 1 {
                self.move_to(self.row + 1, 0, sh)
            }
            self.want_x = -1
        } else if k == "ArrowUp" || k == "ArrowDown" || k == "PageUp" || k == "PageDown" {
            if self.want_x < 0 { self.want_x = self.x_of(self.row, self.col) }
            let step = if k == "ArrowUp" { -1 } else if k == "ArrowDown" { 1 } else if k == "PageUp" { -self.rows() } else { self.rows() }
            let r = max(0, min(self.row + step, self.lines.len() - 1))
            let wx = self.want_x
            self.move_to(r, self.col_at(r, wx), sh)
            self.want_x = wx
        } else if k == "Home" {
            let ind = self.indent_of(self.line()).len()
            self.move_to(self.row, if self.col == ind { 0 } else { ind }, sh)
            self.want_x = -1
        } else if k == "End" {
            self.move_to(self.row, self.line().len(), sh)
            self.want_x = -1
        } else if k == "Escape" {
            self.arow = -1
        } else if k == "Backspace" {
            self.snapshot("delete")
            if self.has_sel() {
                self.delete_sel()
            } else if self.col > 0 {
                let l = self.line()
                // in the indentation: back to the previous multiple of 4
                let ind = self.indent_of(l).len()
                var from = self.char_left(l, self.col)
                if self.col <= ind && self.col > 0 { from = (self.col - 1) / 4 * 4 }
                self.lines[self.row] = l.slice(0, from) + l.slice(self.col, l.len())
                self.col = from
            } else if self.row > 0 {
                let prev = self.lines[self.row - 1]
                self.lines[self.row - 1] = prev + self.line()
                self.lines.remove(self.row)
                self.row -= 1
                self.col = prev.len()
            }
            self.arow = -1
            self.want_x = -1
        } else if k == "Delete" {
            self.snapshot("delete")
            if self.has_sel() {
                self.delete_sel()
            } else if self.col < self.line().len() {
                let l = self.line()
                self.lines[self.row] = l.slice(0, self.col) + l.slice(self.char_right(l, self.col), l.len())
            } else if self.row < self.lines.len() - 1 {
                self.lines[self.row] = self.line() + self.lines[self.row + 1]
                self.lines.remove(self.row + 1)
            }
            self.arow = -1
        } else if k == "Enter" {
            self.snapshot("")
            self.delete_sel()
            let l = self.line()
            var ind = self.indent_of(l)
            let before = l.slice(0, self.col).trim()
            if before.ends_with("{") || before.ends_with("(") || before.ends_with("[") { ind += "    " }
            let after = l.slice(self.col, l.len())
            // between { and }: the } goes on a line of its own
            if (before.ends_with("{") && after.trim().starts_with("}")) {
                self.lines[self.row] = l.slice(0, self.col)
                self.lines.insert(self.row + 1, ind)
                self.lines.insert(self.row + 2, self.indent_of(l) + after.trim())
                self.row += 1
                self.col = ind.len()
            } else {
                self.lines[self.row] = l.slice(0, self.col)
                self.lines.insert(self.row + 1, ind + after.trim())
                self.row += 1
                self.col = ind.len()
            }
            self.want_x = -1
        } else if k == "Tab" {
            self.snapshot("")
            if self.has_sel() || sh {
                self.shift_lines(sh)
            } else {
                let n = 4 - self.col % 4
                self.insert(" ".repeat(n))
            }
        } else if e.text != "" {
            self.snapshot("type")
            let t = e.text
            // typing } on a line of only spaces: back one level
            if t == "}" && self.line().trim() == "" && self.col >= 4 && self.col == self.line().len() {
                self.lines[self.row] = self.line().slice(0, self.col - 4)
                self.col -= 4
            }
            self.insert(t)
            self.want_x = -1
        } else {
            return
        }
        self.reveal()
    }

    // the find / go-to-line bar
    fn bar_key(self, e: input.Event) {
        let k = e.key
        if k == "Escape" {
            self.bar = ""
        } else if k == "Enter" || k == "F3" {
            if self.bar == "find" {
                self.find_next(self.query, true)
            } else {
                let n = int(self.query.trim()) catch 0
                if n > 0 {
                    self.move_to(min(n, self.lines.len()) - 1, 0, false)
                    self.top = max(0, self.row - self.rows() / 2)
                }
                self.bar = ""
            }
        } else if k == "Backspace" {
            let cs = self.query.chars()
            if !cs.is_empty() {
                cs.pop()
                self.query = cs.join("")
            }
        } else if e.text != "" && !e.ctrl {
            self.query += e.text
            // as you type: the first match from where the search started
            if self.bar == "find" { self.find_next(self.query, false) }
        }
    }

    // select the next place `q` is (after the cursor, or at it when `skip` is false), round the end
    fn find_next(self, q: str, skip: bool) {
        if q == "" { return }
        self.last_find = q
        let want = q.lower()
        let n = self.lines.len()
        let start_row = if self.has_sel() { self.sel()[0] } else { self.row }
        let start_col = if self.has_sel() { self.sel()[1] + (if skip { 1 } else { 0 }) } else { self.col }
        for step in 0..n + 1 {
            let r = (start_row + step) % n
            let l = self.lines[r].lower()
            var from = if step == 0 { start_col } else { 0 }
            if step == n { from = 0 }
            if from > l.len() { continue }
            let at = l.slice(from, l.len()).find(want)
            if at >= 0 {
                let c = from + at
                self.arow = r
                self.acol = c
                self.row = r
                self.col = c + q.len()
                self.reveal()
                self.status = "found \"${q}\" on line ${r + 1} (F3 for the next)"
                return
            }
        }
        self.status = "\"${q}\" isn't in the file"
    }

    fn shift_lines(self, back: bool) {
        let s = if self.has_sel() { self.sel() } else { [self.row, self.col, self.row, self.col] }
        for r in s[0]..s[2] + 1 {
            let l = self.lines[r]
            if back {
                let n = min(4, self.indent_of(l).len())
                self.lines[r] = l.slice(n, l.len())
            } else if l != "" {
                self.lines[r] = "    " + l
            }
        }
        self.col = min(self.col, self.line().len())
        if self.arow >= 0 { self.acol = min(self.acol, self.lines[self.arow].len()) }
    }

    fn toggle_comment(self) {
        let s = if self.has_sel() { self.sel() } else { [self.row, self.col, self.row, self.col] }
        var all = true
        for r in s[0]..s[2] + 1 {
            if self.lines[r].trim() != "" && !self.lines[r].trim().starts_with("//") { all = false }
        }
        for r in s[0]..s[2] + 1 {
            let l = self.lines[r]
            let ind = self.indent_of(l)
            if all {
                let rest = l.slice(ind.len(), l.len())
                let cut = if rest.starts_with("// ") { 3 } else if rest.starts_with("//") { 2 } else { 0 }
                self.lines[r] = ind + rest.slice(cut, rest.len())
            } else if l.trim() != "" {
                self.lines[r] = ind + "// " + l.slice(ind.len(), l.len())
            }
        }
        self.col = min(self.col, self.line().len())
    }

    fn console_key(self, e: input.Event) {
        let k = e.key
        if k == "Escape" {
            self.con_focus = false
        } else if k == "Enter" {
            let line = self.con_input
            self.con_input = ""
            if let p = self.p {
                if p.state == "input" {
                    self.out(line + "\n")
                    p.give_line(line)
                }
            }
        } else if k == "Backspace" {
            let s = self.con_input
            self.con_input = s.slice(0, self.char_left(s, s.len()))
        } else if e.text != "" && !e.ctrl {
            self.con_input += e.text
        }
    }

    // ---- the mouse ----

    fn mouse(self, e: input.Event) {
        self.changed = true
        let ex = self.edit_x()
        if e.kind == "wheel" {
            if e.y > self.h - STATUS_H - self.console_h() {
                self.con_back = max(0, self.con_back - e.delta * 3)
            } else if e.x < ex && self.sidebar {
                self.side_top = max(0, self.side_top + e.delta * 2)
            } else {
                self.top = max(0, min(self.top + e.delta * 3, self.lines.len() - 1))
            }
            return
        }
        if e.kind == "button" && e.down && e.button == 0 {
            for b in self.buttons {
                if e.x >= b.x && e.x < b.x + b.w && e.y >= b.y && e.y < b.y + b.h {
                    self.click(b.id)
                    return
                }
            }
            if e.y > self.h - STATUS_H - self.console_h() && e.y < self.h - STATUS_H {
                self.con_focus = true
                return
            }
            if e.y >= BAR_H && e.x >= ex {
                self.con_focus = false
                let r = min(self.top + max(0, e.y - BAR_H - 4) / self.lh, self.lines.len() - 1)
                let c = self.col_at(r, e.x - ex - self.gutter_w() + self.left)
                self.move_to(r, c, e.shift)
                if !e.shift {
                    self.arow = r
                    self.acol = c
                }
                self.dragging = true
                self.want_x = -1
            }
            return
        }
        if e.kind == "button" && !e.down {
            self.dragging = false
            if self.arow == self.row && self.acol == self.col { self.arow = -1 }
            return
        }
        if e.kind == "move" && self.dragging {
            let r = max(0, min(self.top + (e.y - BAR_H - 4) / self.lh, self.lines.len() - 1))
            let c = self.col_at(r, e.x - ex - self.gutter_w() + self.left)
            self.row = r
            self.col = c
            self.reveal()
        }
    }

    fn click(self, id: str) {
        if id == "run" { self.run() }
        else if id == "stop" { self.stop() }
        else if id == "save" { self.save() }
        else if id == "new" { self.new_file() }
        else if id == "files" { self.sidebar = !self.sidebar }
        else if id == "up" {
            self.side_dir = self.env.fs.parent(self.side_dir)
            self.side_top = 0
        } else if id.starts_with("open:") {
            let path = id.slice(5, id.len())
            if self.env.fs.is_dir(path) {
                self.side_dir = path
                self.side_top = 0
            } else {
                self.open_file(path)
            }
        }
    }

    // ---- files ----

    fn new_file(self) {
        self.set_text("fn main() {\n    println(\"hello!\")\n}\n")
        self.path = ""
        self.dirty = false
        self.undo = []
        self.status = "a new program (Ctrl-S saves it)"
        self.title()
    }

    fn open_file(self, path: str) {
        let t = self.env.fs.read(path) catch e {
            self.status = "${e}"
            return
        }
        self.set_text(t)
        self.path = path
        self.dirty = false
        self.undo = []
        self.side_dir = self.env.fs.parent(path)
        self.status = "opened ${path}"
        self.title()
    }

    fn save(self) {
        if self.path == "" {
            // a name from the first fn/struct, else untitled
            var n = 1
            while self.env.fs.exists(self.env.home() + "/program${n}.st") { n += 1 }
            self.path = self.env.home() + "/program${n}.st"
        }
        var note = ""
        if !self.env.can_write(self.path) {
            // not yours (an example, say): a copy in your home
            let mine = self.env.home() + "/" + self.env.fs.name(self.path)
            if !self.env.can_write(mine) {
                self.status = "you may not write ${self.path}"
                return
            }
            note = " (a copy: ${self.path} isn't yours to change)"
            self.path = mine
        }
        var t = self.text()
        if !t.ends_with("\n") { t += "\n" }
        self.env.fs.write(self.path, t) catch e {
            self.status = "couldn't save: ${e}"
            return
        }
        self.dirty = false
        self.status = "saved ${self.path}${note}"
        self.side_dir = self.env.fs.parent(self.path)
        self.title()
    }

    fn title(self) {
        if let w = self.d.find(self.win) {
            w.title = if self.path == "" { "Code" } else { "${self.env.fs.name(self.path)} — Code" }
            self.d.hurt_all()
        }
    }

    // ---- running ----

    fn out(self, s: str) {
        let parts = (self.con_partial + s).split("\n")
        for k in 0..parts.len() - 1 { self.console.push(parts[k]) }
        self.con_partial = parts[parts.len() - 1]
        while self.console.len() > 2000 { self.console.remove(0) }
        self.con_back = 0
        self.changed = true
    }

    fn running(self) -> bool {
        if let p = self.p { return !p.done() }
        return false
    }

    fn stop(self) {
        if let p = self.p {
            if !p.done() { p.kill("stopped") }
        }
    }

    fn run(self) {
        self.stop()
        if self.con_partial != "" { self.out("\n") }
        let name = if self.path == "" { "program" } else { self.env.fs.name(self.path) }
        let t0 = kernel.uptime()
        let res = cc.compile(self.text(), () => kernel.uptime())
        if !res.errors.is_empty() {
            let e = res.errors[0]
            self.err_line = e.line
            self.err_msg = e.msg
            self.out("× ${name}:${e.line}:${e.col}: ${e.msg}\n")
            self.status = "line ${e.line}: ${e.msg}"
            self.move_to(e.line - 1, e.col - 1, false)
            self.reveal()
            self.con_focus = false
            return
        }
        self.err_line = 0
        let ms = kernel.uptime() - t0
        let sys = self.env.sys()
        sys.write = (p: proc.Proc, s: str) => self.out(s)
        let ed = self
        sys.window = (p: proc.Proc) => { progwin.open(ed.d, p) }
        sys.exited = (p: proc.Proc) => {
            if ed.con_partial != "" { ed.out("\n") }
            let how = if p.why != "" { p.why } else { "exit code ${p.code}" }
            ed.out(if p.why == "" && p.code == 0 { "✓ ${p.name} finished\n" } else { "× ${p.name} ended: ${how}\n" })
            ed.status = "${p.name}: ${how}, ${p.cpu} ms of CPU"
            ed.con_focus = false
        }
        let p = self.env.procs.spawn(name, self.env.user(), res.image.bytes, res.image.data_at, res.image.data_size, sys) catch e {
            self.out("× ${e}\n")
            return
        }
        self.p = some(p)
        self.out("▶ ${name}: compiled in ${ms} ms (${res.image.bytes.len() / 1024} KiB), running as process ${p.pid}\n")
        self.status = "running ${name} (process ${p.pid}) — F6 stops it"
    }

    // ---- painting ----

    fn tick(self, t: wm.Tick) -> bool {
        // the cursor blinks; a running program waiting for input wants the console's attention
        if let p = self.p {
            if p.state == "input" && !self.con_focus && kernel.uptime() - self.blink > 0 {
                self.con_focus = true
                self.changed = true
            }
        }
        let c = self.changed
        self.changed = false
        return c
    }

    fn paint(self, s: gfx.Surface) {
        self.w = s.width
        self.h = s.height
        self.cw = max(1, gfx.text_width("M", gfx.MONO))
        self.lh = gfx.line_height(gfx.MONO) + 3
        self.buttons = []
        s.clear(BG)
        self.paint_bar(s)
        if self.sidebar { self.paint_side(s) }
        self.paint_text(s)
        self.paint_console(s)
        self.paint_status(s)
    }

    fn button(self, s: gfx.Surface, x: int, label: str, id: str, color: int, enabled: bool) -> int {
        let w = gfx.text_width(label, gfx.UI_BOLD) + 22
        let y = 6
        let h = BAR_H - 12
        s.round(x, y, w, h, 6, if enabled { color } else { 0x3a3d4f })
        s.text(x + 11, y + 6, label, if enabled { 0xffffff } else { 0x8a8fa6 }, gfx.UI_BOLD)
        if enabled { self.buttons.push(Button { x, y, w, h, id }) }
        return x + w + 8
    }

    fn paint_bar(self, s: gfx.Surface) {
        s.rect(0, 0, self.w, BAR_H, BAR)
        var x = 8
        x = self.button(s, x, "☰", "files", 0x3a3d4f, true)
        x = self.button(s, x, "New", "new", 0x3a3d4f, true)
        x = self.button(s, x, "Save", "save", 0x3a3d4f, true)
        x = self.button(s, x, "▶ Run", "run", 0x2e9e6b, true)
        x = self.button(s, x, "■ Stop", "stop", 0xc0392b, self.running())
        let name = if self.path == "" { "untitled" } else { self.path }
        let label = name + if self.dirty { " •" } else { "" }
        s.text(x + 8, 12, wm.fit(label, gfx.UI, self.w - x - 16), 0xaeb4cf, gfx.UI)
    }

    fn paint_side(self, s: gfx.Surface) {
        let y0 = BAR_H
        let h = self.h - BAR_H - STATUS_H
        s.rect(0, y0, SIDE_W, h, GUTTER)
        s.rect(SIDE_W - 1, y0, 1, h, 0x2c2e3d)
        if self.side_dir == "" || !self.env.fs.is_dir(self.side_dir) { self.side_dir = self.env.home() }
        let dir = self.side_dir
        s.text(10, y0 + 8, wm.fit(dir, gfx.UI_BOLD, SIDE_W - 50), 0xaeb4cf, gfx.UI_BOLD)
        if dir != "/" {
            s.round(SIDE_W - 34, y0 + 5, 26, 20, 5, 0x3a3d4f)
            s.text(SIDE_W - 26, y0 + 7, "↑", 0xffffff, gfx.UI_BOLD)
            self.buttons.push(Button { x: SIDE_W - 34, y: y0 + 5, w: 26, h: 20, id: "up" })
        }
        let entries = self.env.fs.list(dir)
        var y = y0 + 32
        let rh = 22
        self.side_top = min(self.side_top, max(0, entries.len() - 3))
        for k in self.side_top..entries.len() {
            if y + rh > y0 + h { break }
            let e = entries[k]
            let is_dir = e.ends_with("/")
            let name = if is_dir { e.slice(0, e.len() - 1) } else { e }
            let path = self.env.fs.resolve(dir, name)
            let current = path == self.path
            if current { s.rect(0, y, SIDE_W - 1, rh, 0x2c3045) }
            let icon = if is_dir { "▤" } else if name.ends_with(".st") { "✦" } else { "≡" }
            let ic = if is_dir { 0x82aaff } else if name.ends_with(".st") { 0xc792ea } else { DIM }
            s.text(12, y + 3, icon, ic, gfx.UI)
            s.text(28, y + 3, wm.fit(name, gfx.UI, SIDE_W - 36), if current { 0xffffff } else { 0xc8cde0 }, gfx.UI)
            self.buttons.push(Button { x: 0, y, w: SIDE_W - 1, h: rh, id: "open:" + path })
            y += rh
        }
    }

    fn paint_text(self, s: gfx.Surface) {
        let ex = self.edit_x()
        let y0 = BAR_H
        let eh = self.edit_h()
        let gw = self.gutter_w()
        s.rect(ex, y0, gw, eh, GUTTER)
        let n = self.rows()
        self.top = max(0, min(self.top, self.lines.len() - 1))
        let has = self.has_sel()
        let sl = self.sel()
        s.clip(ex + gw, y0, self.w - ex - gw, eh)
        for i in 0..n + 1 {
            let r = self.top + i
            if r >= self.lines.len() { break }
            let y = y0 + 4 + i * self.lh
            if r == self.row && !has { s.rect(ex + gw, y - 1, self.w - ex - gw, self.lh, LINE_HL) }
            if r == self.err_line - 1 { s.shade(ex + gw, y - 1, self.w - ex - gw, self.lh, ERROR, 40) }
            let tx = ex + gw + 8 - self.left
            // the selection
            if has && r >= sl[0] && r <= sl[2] {
                let c0 = if r == sl[0] { sl[1] } else { 0 }
                let c1 = if r == sl[2] { sl[3] } else { self.lines[r].len() }
                let x0 = tx + self.x_of(r, c0)
                let x1 = tx + self.x_of(r, c1) + if r < sl[2] { self.cw / 2 } else { 0 }
                s.rect(x0, y - 1, max(x1 - x0, 0), self.lh, SEL)
            }
            self.paint_line(s, tx, y, self.lines[r])
            if r == self.row && !self.con_focus {
                let cx = tx + self.x_of(r, self.col)
                s.rect(cx, y - 1, 2, self.lh, 0xffcc00)
            }
        }
        s.unclip()
        // line numbers
        for i in 0..n + 1 {
            let r = self.top + i
            if r >= self.lines.len() { break }
            let y = y0 + 4 + i * self.lh
            let num = "${r + 1}"
            let col = if r == self.err_line - 1 { ERROR } else if r == self.row { 0xc8cde0 } else { DIM }
            s.text(ex + gw - 8 - gfx.text_width(num, gfx.MONO), y, num, col, gfx.MONO)
            if r == self.err_line - 1 { s.circle(ex + 6, y + self.lh / 2 - 1, 3, ERROR) }
        }
        if self.bar != "" {
            let by = y0 + eh - 34
            s.rect(ex + gw, by, self.w - ex - gw, 34, 0x2c2e3d)
            let label = if self.bar == "find" { "Find" } else { "Go to line" }
            s.text(ex + gw + 12, by + 9, label, 0xaeb4cf, gfx.UI_BOLD)
            let fx = ex + gw + 20 + gfx.text_width(label, gfx.UI_BOLD)
            s.round(fx, by + 5, 260, 24, 5, 0x1e1f29)
            s.text(fx + 8, by + 8, self.query, 0xffffff, gfx.MONO)
            s.rect(fx + 9 + gfx.text_width(self.query, gfx.MONO), by + 9, 2, 16, 0xffcc00)
            s.text(fx + 272, by + 9, if self.bar == "find" { "Enter: next · Esc: close" } else { "Enter: go · Esc: close" }, DIM, gfx.UI)
        }
        // the error: after its line if there's room, else under it
        if self.err_line > 0 && self.err_line - 1 >= self.top && self.err_line - 1 < self.top + n {
            let r = self.err_line - 1
            let msg = "  " + self.err_msg + "  "
            let mw = gfx.text_width(msg, gfx.UI)
            let after = ex + gw + 8 - self.left + self.x_of(r, self.lines[r].len()) + 24
            var x = after
            var y = y0 + 4 + (r - self.top) * self.lh
            if after + mw > self.w - 8 {
                x = ex + gw + 8
                y += self.lh
            }
            let w = min(mw, self.w - x - 8)
            s.round(x, y - 1, w, self.lh, 4, 0x5c1f2a)
            s.text(x, y + 1, wm.fit(msg, gfx.UI, w), 0xffd5dc, gfx.UI)
        }
    }

    // one line, in colors
    fn paint_line(self, s: gfx.Surface, x0: int, y: int, l: str) {
        var x = x0
        let n = l.len()
        var i = 0
        while i < n {
            let c = l[i]
            var j = i + 1
            var color = TEXT
            if c == "/" && i + 1 < n && l[i + 1] == "/" {
                j = n
                color = COMMENT
            } else if c == "\"" {
                var depth = 0
                while j < n {
                    let d = l[j]
                    if d == "\\" {
                        j += 2
                        continue
                    }
                    if d == "{" && l[j - 1] == "$" { depth += 1 }
                    if d == "}" && depth > 0 { depth -= 1 }
                    j += 1
                    if d == "\"" && depth == 0 { break }
                }
                j = min(j, n)
                color = STRING
            } else if is_digit_s(c) {
                while j < n && (is_word(l, j)) { j += 1 }
                color = NUMBER
            } else if is_word(l, i) {
                while j < n && is_word(l, j) { j += 1 }
                let w = l.slice(i, j)
                if KEYWORDS.contains(w) { color = KEYWORD }
                else if TYPES.contains(w) { color = TYPE }
                else if w[0] >= "A" && w[0] <= "Z" { color = TYPE }
                else if j < n && l[j] == "(" && BUILTINS.contains(w) { color = BUILTIN }
                else if j < n && l[j] == "(" { color = 0x7fdbca }
            } else if c == " " {
                while j < n && l[j] == " " { j += 1 }
            } else {
                while j < n && !is_word(l, j) && l[j] != "\"" && l[j] != "/" && l[j] != " " { j += 1 }
                color = 0x89ddff
            }
            let part = l.slice(i, j)
            if c != " " { s.text(x, y, part, color, gfx.MONO) }
            x += gfx.text_width(part, gfx.MONO)
            i = j
        }
    }

    fn paint_console(self, s: gfx.Surface) {
        let ch = self.console_h()
        let y0 = self.h - STATUS_H - ch
        let ex = 0
        s.rect(ex, y0, self.w, ch, CONSOLE)
        s.rect(ex, y0, self.w, 1, if self.con_focus { 0xffcc00 } else { 0x2c2e3d })
        s.text(ex + 10, y0 + 5, "CONSOLE", DIM, gfx.UI_BOLD)
        if self.running() {
            if let p = self.p {
                let what = if p.state == "input" { "waiting for you to type a line (Enter sends)" } else { "process ${p.pid} running" }
                s.text(ex + 80, y0 + 5, what, if p.state == "input" { 0xffcc00 } else { OK }, gfx.UI)
            }
        }
        let lh = gfx.line_height(gfx.MONO) + 2
        let rows = max(1, (ch - 30) / lh)
        var all = self.console.slice(0, self.console.len())
        all.push(self.con_partial + if self.con_focus { self.con_input } else { "" })
        let last = max(0, all.len() - self.con_back)
        let first = max(0, last - rows)
        for k in first..last {
            let l = all[k]
            let y = y0 + 24 + (k - first) * lh
            let color = if l.starts_with("×") || l.starts_with("error") { 0xff8a9a } else if l.starts_with("✓") || l.starts_with("▶") { OK } else { 0xd0d4e4 }
            s.text(ex + 10, y, wm.fit(l, gfx.MONO, self.w - 20), color, gfx.MONO)
            if k == all.len() - 1 && self.con_focus {
                let cx = ex + 10 + gfx.text_width(l, gfx.MONO)
                s.rect(cx, y, 8, lh - 2, 0xffcc00)
            }
        }
    }

    fn paint_status(self, s: gfx.Surface) {
        let y = self.h - STATUS_H
        s.rect(0, y, self.w, STATUS_H, if self.err_line > 0 { 0x5c1f2a } else { 0x2c2e3d })
        s.text(10, y + 4, wm.fit(self.status, gfx.UI, self.w - 180), 0xd0d4e4, gfx.UI)
        let pos = "Ln ${self.row + 1}, Col ${self.col + 1}"
        s.text(self.w - gfx.text_width(pos, gfx.UI) - 10, y + 4, pos, 0xaeb4cf, gfx.UI)
    }
}

fn is_cont(l: str, k: int) -> bool {
    let c = st_k_byte(l, k)
    return c >= 128 && c < 192
}
extern fn st_k_byte(s: str, i: int) -> int

fn is_word(l: str, k: int) -> bool {
    let c = st_k_byte(l, k)
    return c >= 97 && c <= 122 || c >= 65 && c <= 90 || c >= 48 && c <= 57 || c == 95
}
fn is_digit_s(c: str) -> bool { return c >= "0" && c <= "9" }

// one clipboard for the whole system (kept by the kernel)
extern fn st_storage_get(key: str) -> str
extern fn st_storage_set(key: str, value: str)
fn clipboard_set(t: str) { st_storage_set("clipboard", t) }
fn clipboard_get() -> str { return st_storage_get("clipboard") }

fn open(d: wm.Desktop, env: Env, path: str) -> Editor {
    let ed = Editor { d, env }
    if path != "" { ed.open_file(path) } else { ed.new_file() }
    let w = d.open("Code", "{}", 0x6c5ce7, 820, 600, wm.App {
        tick: (t: wm.Tick) => ed.tick(t),
        paint: (s: gfx.Surface) => ed.paint(s),
        key: (e: input.Event) => ed.key(e),
        mouse: (e: input.Event) => ed.mouse(e),
        close: () => ed.stop(),
    })
    ed.win = w.id
    ed.title()
    return ed
}
