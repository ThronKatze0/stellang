// login: the screen in front of the desktop until someone logs in. On a fresh system it asks for
// the first account instead (that person becomes the administrator).

import kernel
import gfx
import input
import wm

struct Field {
    label: str,
    value: str = "",
    secret: bool = false,
}

struct Screen {
    d: wm.Desktop,
    setup: bool,                       // no accounts yet: create the first
    fields: [Field] = [],
    focus: int = 0,
    message: str = "",
    error: bool = false,
    busy: int = 0,                     // 2: show "checking" first, 1: do it now
    changed: bool = true,
    login: fn(str, str) -> str,        // "" or what went wrong
    create: fn(str, str) -> str,
    hits: [[int]] = [],                // [x, y, w, h, what] (what: field index, or -1 the button)
    last_second: int = -1,
    bg: gfx.Surface? = none,           // the dimmed wallpaper, made once

    fn reset(self, setup: bool, name: str) {
        self.setup = setup
        self.fields = if setup {
            [Field { label: "Choose a user name" }, Field { label: "Password", secret: true }, Field { label: "Password again", secret: true }]
        } else {
            [Field { label: "User name", value: name }, Field { label: "Password", secret: true }]
        }
        self.focus = if !setup && name != "" { 1 } else { 0 }
        self.message = if setup { "No accounts yet: the first one is the administrator." } else { "" }
        self.error = false
        self.changed = true
    }

    fn submit(self) {
        if self.busy > 0 { return }
        if self.fields[0].value.trim() == "" {
            self.say("type a user name", true)
            self.focus = 0
            return
        }
        if self.setup && self.fields[1].value != self.fields[2].value {
            self.say("the two passwords aren't the same", true)
            self.fields[2].value = ""
            self.focus = 2
            return
        }
        self.message = if self.setup { "Creating your account…" } else { "Checking…" }
        self.error = false
        self.busy = 2
        self.changed = true
    }

    fn say(self, m: str, bad: bool) {
        self.message = m
        self.error = bad
        self.changed = true
    }

    fn tick(self, t: wm.Tick) -> bool {
        if self.busy == 1 {
            let name = self.fields[0].value.trim()
            let pw = self.fields[1].value
            let problem = if self.setup { self.create(name, pw) } else { self.login(name, pw) }
            self.busy = 0
            if problem != "" {
                self.say(problem, true)
                self.fields[1].value = ""
                if self.setup { self.fields[2].value = "" }
                self.focus = 1
            }
            self.changed = true
        } else if self.busy == 2 {
            self.busy = 1           // painted "checking" first; the hashing takes a moment
        }
        let sec = kernel.uptime() / 1000
        if sec != self.last_second {
            self.last_second = sec
            self.changed = true
        }
        let c = self.changed
        self.changed = false
        return c
    }

    fn key(self, e: input.Event) {
        if !e.down || self.busy > 0 { return }
        let f = self.fields[self.focus]
        if e.key == "Enter" {
            if self.focus < self.fields.len() - 1 && (f.value == "" || self.focus == 0) {
                self.focus += 1
            } else {
                self.submit()
            }
        } else if e.key == "Tab" {
            self.focus = (self.focus + if e.shift { self.fields.len() - 1 } else { 1 }) % self.fields.len()
        } else if e.key == "Backspace" {
            let cs = f.value.chars()
            if !cs.is_empty() {
                cs.pop()
                f.value = cs.join("")
            }
        } else if e.key == "Escape" {
            f.value = ""
        } else if e.text != "" && !e.ctrl && f.value.len() < 64 {
            f.value += e.text
        }
        self.changed = true
    }

    fn mouse(self, e: input.Event) {
        if e.kind != "button" || !e.down || self.busy > 0 { return }
        for h in self.hits {
            if e.x >= h[0] && e.x < h[0] + h[2] && e.y >= h[1] && e.y < h[1] + h[3] {
                if h[4] < 0 { self.submit() } else { self.focus = h[4] }
                self.changed = true
                return
            }
        }
    }

    fn paint(self, s: gfx.Surface) {
        if self.bg == none {
            let bg = gfx.surface(s.width, s.height)
            bg.draw(self.d.wallpaper, 0, 0)
            bg.shade(0, 0, s.width, s.height, 0x0b0820, 120)
            self.bg = some(bg)
        }
        if let bg = self.bg { s.draw(bg, 0, 0) }
        self.hits = []
        // the time, big
        let t = kernel.date(kernel.time_ms())
        let clock = "${kernel.two(t.hour)}:${kernel.two(t.minute)}"
        s.text_in(0, 70, s.width, 50, clock, 0xffffff, gfx.BIG)
        s.text_in(0, 118, s.width, 24, "${kernel.WEEKDAYS[t.weekday]} ${t.day} ${kernel.MONTHS[t.month - 1]}", 0xd8d2ff, gfx.TEXT)
        // the card
        let cw = 380
        let ch = 168 + self.fields.len() * 62
        let cx = (s.width - cw) / 2
        let cy = max(170, (s.height - ch) / 2 + 30)
        s.round_shade(cx + 4, cy + 6, cw, ch, 16, 0x000000, 70)
        s.round(cx, cy, cw, ch, 16, 0xfbfaff)
        // an avatar: the first letter of the name
        let name = self.fields[0].value.trim()
        let initial = if name == "" { "✦" } else { name.chars()[0].upper() }
        s.circle(cx + cw / 2, cy + 2, 34, 0x6c5ce7)
        s.circle(cx + cw / 2, cy + 2, 30, 0x8c7cf7)
        s.text_in(cx + cw / 2 - 30, cy - 22, 60, 48, initial, 0xffffff, gfx.TITLE)
        let title = if self.setup { "Welcome to StellaOS" } else { "Log in" }
        s.text_in(cx, cy + 42, cw, 28, title, 0x2d2a40, gfx.TITLE)
        var y = cy + 84
        for k, f in self.fields {
            s.text(cx + 30, y, f.label, 0x6b6880, gfx.UI_BOLD)
            let fy = y + 18
            let focused = k == self.focus
            s.round(cx + 28, fy, cw - 56, 34, 8, if focused { 0x6c5ce7 } else { 0xd9d6e6 })
            s.round(cx + 30, fy + 2, cw - 60, 30, 7, 0xffffff)
            let shown = if f.secret { "•".repeat(f.value.chars().len()) } else { f.value }
            let tw = s.text(cx + 40, fy + 7, wm.fit(shown, gfx.TEXT, cw - 90), 0x2d2a40, gfx.TEXT)
            if focused && (kernel.uptime() / 500) % 2 == 0 {
                s.rect(cx + 40 + gfx.text_width(wm.fit(shown, gfx.TEXT, cw - 90), gfx.TEXT) + 1, fy + 7, 2, 20, 0x6c5ce7)
            }
            self.hits.push([cx + 28, fy, cw - 56, 34, k])
            y += 62
        }
        // the button
        let label = if self.setup { "Create account" } else { "Log in" }
        let bw = cw - 56
        s.round(cx + 28, y + 2, bw, 38, 9, if self.busy > 0 { 0xa29bfe } else { 0x6c5ce7 })
        s.text_in(cx + 28, y + 2, bw, 38, label, 0xffffff, gfx.TEXT_BOLD)
        self.hits.push([cx + 28, y + 2, bw, 38, -1])
        if self.message != "" {
            let color = if self.error { 0xd63031 } else { 0x6b6880 }
            s.text_in(cx + 10, y + 46, cw - 20, 20, wm.fit(self.message, gfx.UI, cw - 20), color, gfx.UI)
        }
        s.text_in(0, s.height - 34, s.width, 20, "StellaOS · Tab moves between fields · Enter logs in", 0xb8b2e0, gfx.UI)
    }
}

fn screen(d: wm.Desktop, setup: bool, name: str, login: fn(str, str) -> str, create: fn(str, str) -> str) -> Screen {
    let sc = Screen { d, setup, login, create }
    sc.reset(setup, name)
    return sc
}

fn app(sc: Screen) -> wm.App {
    return wm.App {
        tick: (t: wm.Tick) => sc.tick(t),
        paint: (s: gfx.Surface) => sc.paint(s),
        key: (e: input.Event) => sc.key(e),
        mouse: (e: input.Event) => sc.mouse(e),
    }
}
