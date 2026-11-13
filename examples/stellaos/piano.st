// Piano: an octave and a bit on the sound card. Click the keys, or play on the keyboard: A S D F
// G H J K L are the white keys, W E T Y U O P the black ones; Z/X go an octave down/up.

import gfx
import input
import wm

const WHITE = ["C", "D", "E", "F", "G", "A", "B", "C", "D", "E"]
const WHITE_KEYS = ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"]
// the black keys: after which white key (index), and their letter
const BLACK_AFTER = [0, 1, 3, 4, 5, 7, 8]
const BLACK_KEYS = ["w", "e", "t", "y", "u", "o", "p"]
const KEY_W = 46
const KEY_H = 190

struct Piano {
    beep: fn(int, int),
    octave: int = 4,
    lit: [int] = [],          // semitones lit up, until a moment later
    lit_until: [int] = [],
    now: int = 0,
    changed: bool = true,
    last: str = "",

    // semitones above the octave's C
    fn white_semi(self, i: int) -> int {
        let steps = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16]
        return steps[i]
    }
    fn black_semi(self, i: int) -> int { return self.white_semi(BLACK_AFTER[i]) + 1 }

    fn hz(self, semi: int) -> int {
        // A4 = 440: 2^(n/12) by a table of one octave
        let table = [262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494]
        var f = table[semi % 12] * (1 << (semi / 12))
        var o = self.octave
        while o > 4 {
            f = f * 2
            o -= 1
        }
        while o < 4 {
            f = f / 2
            o += 1
        }
        return f
    }

    fn play(self, semi: int, name: str) {
        self.beep(self.hz(semi), 260)
        self.lit.push(semi)
        self.lit_until.push(self.now + 180)
        self.last = "${name}${self.octave + semi / 12}"
        self.changed = true
    }

    fn tick(self, t: wm.Tick) -> bool {
        self.now = t.now
        var k = 0
        while k < self.lit.len() {
            if self.lit_until[k] < t.now {
                self.lit.remove(k)
                self.lit_until.remove(k)
                self.changed = true
            } else {
                k += 1
            }
        }
        let c = self.changed
        self.changed = false
        return c
    }

    fn key(self, e: input.Event) {
        if !e.down || e.repeat { return }
        let k = e.key.lower()
        let w = WHITE_KEYS.index_of(k)
        if w >= 0 {
            self.play(self.white_semi(w), WHITE[w])
            return
        }
        let b = BLACK_KEYS.index_of(k)
        if b >= 0 {
            self.play(self.black_semi(b), WHITE[BLACK_AFTER[b]] + "#")
            return
        }
        if k == "z" && self.octave > 2 { self.octave -= 1 }
        if k == "x" && self.octave < 6 { self.octave += 1 }
        self.changed = true
    }

    fn mouse(self, e: input.Event) {
        if e.kind != "button" || !e.down { return }
        let y = e.y - 50
        if y < 0 || y > KEY_H { return }
        // black keys first: they're on top
        if y < KEY_H * 6 / 10 {
            for i, after in BLACK_AFTER {
                let x = 20 + (after + 1) * KEY_W - KEY_W / 3
                if e.x >= x && e.x < x + KEY_W * 2 / 3 {
                    self.play(self.black_semi(i), WHITE[after] + "#")
                    return
                }
            }
        }
        let w = (e.x - 20) / KEY_W
        if e.x >= 20 && w >= 0 && w < WHITE.len() { self.play(self.white_semi(w), WHITE[w]) }
    }

    fn paint(self, s: gfx.Surface) {
        s.gradient(0, 0, s.width, s.height, 0x2d2440, 0x1b1528)
        s.text(20, 14, "Octave ${self.octave}  (Z / X)", 0xd8d2ff, gfx.UI_BOLD)
        if self.last != "" { s.text(s.width - 80, 10, self.last, 0xffeaa7, gfx.TITLE) }
        for i in 0..WHITE.len() {
            let x = 20 + i * KEY_W
            let on = self.lit.contains(self.white_semi(i))
            s.round(x, 50, KEY_W - 3, KEY_H, 6, if on { 0xffeaa7 } else { 0xfbfaff })
            s.text_in(x, 50 + KEY_H - 46, KEY_W - 3, 20, WHITE[i], 0x6b6880, gfx.UI_BOLD)
            s.text_in(x, 50 + KEY_H - 26, KEY_W - 3, 20, WHITE_KEYS[i].upper(), 0xb0adc0, gfx.UI)
        }
        for i, after in BLACK_AFTER {
            let x = 20 + (after + 1) * KEY_W - KEY_W / 3
            let on = self.lit.contains(self.black_semi(i))
            s.round(x, 50, KEY_W * 2 / 3, KEY_H * 6 / 10, 5, if on { 0xfdcb6e } else { 0x1e1b2b })
            s.text_in(x, 50 + KEY_H * 6 / 10 - 24, KEY_W * 2 / 3, 18, BLACK_KEYS[i].upper(), 0x8d88a8, gfx.UI)
        }
    }
}

fn open(d: wm.Desktop, beep: fn(int, int)) {
    let p = Piano { beep }
    let w = d.open("Piano", "♪", 0xa29bfe, 20 * 2 + KEY_W * 10, 270, wm.App {
        tick: (t: wm.Tick) => p.tick(t),
        paint: (s: gfx.Surface) => p.paint(s),
        key: (e: input.Event) => p.key(e),
        mouse: (e: input.Event) => p.mouse(e),
    })
    w.resizable = false
}
