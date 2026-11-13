// progwin: the window of a program that draws (window(), rect(), show(), ... in its code). The
// program draws into a canvas of its own (proc.st); every show() puts that frame on the screen.
// Keys and the mouse go to the program while its window has the focus; closing the window ends it.

import gfx
import input
import wm
import proc

struct View {
    p: proc.Proc,
    fresh: bool = true,
    ended: bool = false,
}

fn open(d: wm.Desktop, p: proc.Proc) -> wm.Window? {
    if let cv = p.canvas {
        let v = View { p }
        let title = if p.title != "" { p.title } else { p.name }
        let w = d.open(title, "▶", 0x00b894, cv.width, cv.height, wm.App {
            tick: (t: wm.Tick) => {
                if v.p.done() && !v.ended {
                    v.ended = true
                    v.fresh = true
                }
                let f = v.fresh
                v.fresh = false
                return f
            },
            paint: (s: gfx.Surface) => {
                if let c = v.p.canvas { s.draw(c, 0, 0) }
                if v.p.done() {
                    s.shade(0, s.height - 24, s.width, 24, 0x000000, 160)
                    let msg = if v.p.why != "" { v.p.why } else { "the program ended (exit code ${v.p.code})" }
                    s.text(8, s.height - 20, wm.fit(msg, gfx.UI, s.width - 16), 0xffffff, gfx.UI)
                }
            },
            key: (e: input.Event) => {
                if e.down && v.p.keys.len() < 64 { v.p.keys.push(e.key) }
            },
            mouse: (e: input.Event) => {
                v.p.mx = e.x
                v.p.my = e.y
                if e.kind == "button" {
                    let bit = 1 << e.button
                    v.p.buttons = if e.down { v.p.buttons | bit } else { v.p.buttons & ~bit }
                }
            },
            close: () => v.p.kill("its window was closed"),
        })
        w.resizable = false
        // show() marks the view fresh
        let old = p.sys.show
        p.sys.show = (q: proc.Proc) => {
            v.fresh = true
            old(q)
        }
        return some(w)
    }
    return none
}
