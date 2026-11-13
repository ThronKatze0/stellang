// The desktop: a wallpaper, windows and a taskbar with a clock, drawn on the framebuffer.
// (No mouse yet: that's a virtio-input driver away.)

import kernel
import gfx

const TITLE = 0x2b2140
const ACCENT = 0xc77dff
const PANEL = 0xf4f0fa
const INK = 0x2a2238

struct Window {
    title: str,
    x: int,
    y: int,
    w: int,
    h: int,
    lines: [str],
}

fn draw_window(s: gfx.Screen, win: Window) {
    s.rect(win.x + 6, win.y + 6, win.w, win.h, 0x1a1028)          // shadow
    s.rect(win.x, win.y, win.w, win.h, PANEL)
    s.rect(win.x, win.y, win.w, 28, TITLE)
    s.text(win.x + 10, win.y + 7, win.title, 0xffffff, 2)
    for i, c in [0xff5f57, 0xfebc2e, 0x28c840] {
        s.rect(win.x + win.w - 24 - i * 18, win.y + 9, 10, 10, c)
    }
    s.frame(win.x, win.y, win.w, win.h, TITLE)
    for i, line in win.lines {
        s.text(win.x + 12, win.y + 42 + i * 20, line, INK, 2)
    }
}

fn draw_taskbar(s: gfx.Screen) {
    let y = s.height - 36
    s.rect(0, y, s.width, 36, 0x140c22)
    s.rect(0, y, s.width, 1, ACCENT)
    s.rect(10, y + 8, 20, 20, ACCENT)
    s.text(40, y + 11, "StellaOS", 0xffffff, 2)
    let secs = kernel.uptime() / 1000
    let clock = "up ${two(secs / 3600)}:${two(secs / 60 % 60)}:${two(secs % 60)}"
    s.rect(s.width - 200, y + 4, 200, 30, 0x140c22)
    s.text(s.width - 12 - clock.len() * 12, y + 11, clock, 0xe0d0ff, 2)
}

fn two(n: int) -> str {
    return if n < 10 { "0${n}" } else { "${n}" }
}

// Draw everything; `info` fills the system window. Returns the screen, kept up to date by a timer.
fn show(info: [str], files: [str]) -> gfx.Screen! {
    let s = gfx.open(1024, 768)?
    s.gradient(0x3a1c71, 0xd76d77)
    s.text(40, 40, "StellaOS", 0xffffff, 6)
    s.text(44, 96, "an operating system written in stellang", 0xf0e0ff, 2)
    draw_window(s, Window { title: "System", x: 60, y: 170, w: 470, h: 230, lines: info })
    draw_window(s, Window { title: "Files", x: 580, y: 240, w: 380, h: 300, lines: files })
    draw_window(s, Window { title: "Hello", x: 160, y: 450, w: 360, h: 150, lines: ["Hello from bare metal!", "", "Drawn by a stellang driver."] })
    draw_taskbar(s)
    kernel.every(1000, () => draw_taskbar(s))
    return s
}
