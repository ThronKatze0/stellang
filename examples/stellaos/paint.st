// Paint: draw with the mouse. Pick a color and a brush size from the bar; the right button erases.

import gfx
import input
import wm

const BAR = 44
const COLORS = [0x2d3436, 0xd63031, 0xe17055, 0xfdcb6e, 0x00b894, 0x0984e3, 0x6c5ce7, 0xe84393, 0xffffff]
const SIZES = [2, 5, 10, 20]

struct Paint {
    canvas: gfx.Surface,
    color: int = 0x2d3436,
    size: int = 5,
    drawing: int = -1,        // the button held (0 draw, 1 erase), or -1
    lx: int = 0,
    ly: int = 0,
    changed: bool = true,

    fn mouse(self, e: input.Event) {
        if e.kind == "button" {
            if e.down && e.y < BAR {
                self.toolbar(e.x)
                return
            }
            self.drawing = if e.down { e.button } else { -1 }
            self.lx = e.x
            self.ly = e.y - BAR
            if e.down { self.stroke(e.x, e.y - BAR) }
        } else if e.kind == "move" && self.drawing >= 0 {
            self.stroke(e.x, e.y - BAR)
        }
    }

    fn stroke(self, x: int, y: int) {
        let c = if self.drawing == 1 { 0xffffff } else { self.color }
        let r = if self.drawing == 1 { self.size + 6 } else { self.size }
        // dots along the way, so fast strokes stay unbroken
        let dist = max(abs(x - self.lx), abs(y - self.ly))
        let n = max(dist / max(r / 2, 1), 1)
        for i in 0..n + 1 {
            self.canvas.circle(self.lx + (x - self.lx) * i / n, self.ly + (y - self.ly) * i / n, r, c)
        }
        self.lx = x
        self.ly = y
        self.changed = true
    }

    fn toolbar(self, x: int) {
        for i, c in COLORS {
            if x >= 10 + i * 30 && x < 36 + i * 30 { self.color = c }
        }
        let sx = 10 + COLORS.len() * 30 + 14
        for i, sz in SIZES {
            if x >= sx + i * 30 && x < sx + i * 30 + 26 { self.size = sz }
        }
        if x >= self.canvas.width - 70 { self.canvas.clear(0xffffff) }
        self.changed = true
    }

    fn paint(self, s: gfx.Surface) {
        if s.width != self.canvas.width || s.height - BAR != self.canvas.height {
            // resized: keep the drawing on a new canvas
            let c = gfx.surface(s.width, max(s.height - BAR, 1))
            c.clear(0xffffff)
            c.draw(self.canvas, 0, 0)
            self.canvas = c
        }
        s.rect(0, 0, s.width, BAR, 0xf3f2f8)
        s.rect(0, BAR - 1, s.width, 1, 0xdddbe6)
        for i, c in COLORS {
            let x = 10 + i * 30
            if c == self.color { s.round(x - 3, 6, 32, 32, 9, 0x6c5ce7) }
            s.round(x, 9, 26, 26, 7, 0xc9c6d4)
            s.round(x + 1, 10, 24, 24, 6, c)
        }
        let sx = 10 + COLORS.len() * 30 + 14
        for i, sz in SIZES {
            let x = sx + i * 30
            if sz == self.size { s.round(x, 9, 26, 26, 7, 0xdcd8ee) }
            s.circle(x + 13, 22, max(sz / 2, 1) + 1, 0x2d3436)
        }
        let cx = s.width - 70
        s.round(cx, 9, 60, 26, 7, 0xe4e2ec)
        s.text_in(cx, 9, 60, 26, "Clear", 0x2d3436, gfx.UI)
        s.draw(self.canvas, 0, BAR)
    }
}

fn open(d: wm.Desktop) {
    let p = Paint { canvas: gfx.surface(560, 380) }
    p.canvas.clear(0xffffff)
    d.open("Paint", "✎", 0xe84393, 560, 380 + BAR, wm.App {
        tick: (t: wm.Tick) => {
            let c = p.changed
            p.changed = false
            return c
        },
        paint: (s: gfx.Surface) => p.paint(s),
        mouse: (e: input.Event) => p.mouse(e),
    })
}
