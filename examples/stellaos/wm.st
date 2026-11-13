// The window manager: StellaOS's desktop. It owns the display, the keyboard and the mouse; apps
// get a window (a surface they paint) and the input that's meant for them.
//
// Drawing is composited: each window keeps its own picture, and the screen is put together from
// the wallpaper, the windows (back to front), the taskbar and the pointer in a back buffer, then
// copied to the display. Only the parts that changed (the "damage") are redone each frame.
//
// It runs as a 60 Hz timer job (kernel.every), so the shell on the serial console keeps going.

import kernel
import gfx
import display
import input

const TITLE_H = 30
const TASKBAR_H = 40
const RADIUS = 9
const ACCENT = 0x7c5cff

// What a window's program does. Every part is optional.
struct App {
    // Each frame: return true to have the window repainted.
    tick: fn(Tick) -> bool = (t: Tick) => false,
    // Draw the whole window content (its size is the surface's).
    paint: fn(gfx.Surface) = (s: gfx.Surface) => {},
    // A key, while the window has the focus.
    key: fn(input.Event) = (e: input.Event) => {},
    // The pointer, in the window's coordinates ("move", "button", "wheel", and "leave").
    mouse: fn(input.Event) = (e: input.Event) => {},
    // The window is closing.
    close: fn() = () => {},
}

struct Tick {
    dt: int,                  // milliseconds since the last frame
    now: int,                 // milliseconds since boot
    signals: bool,            // a signal changed since the last frame (UI apps re-render)
    focused: bool,            // this window has the keyboard
}

struct Window {
    id: int,
    title: str,
    icon: str,
    color: int,
    x: int,                   // the frame's top left on the screen
    y: int,
    w: int,                   // the content's size
    h: int,
    app: App,
    surface: gfx.Surface,
    resizable: bool = true,
    minimized: bool = false,
    maximized: bool = false,
    saved: [int] = [],        // the size and place before maximizing
    dirty: bool = true,

    fn outer_w(self) -> int { return self.w + 2 }
    fn outer_h(self) -> int { return self.h + TITLE_H + 1 }
    fn content_x(self) -> int { return self.x + 1 }
    fn content_y(self) -> int { return self.y + TITLE_H }

    // the screen area it covers, shadow included
    fn area(self) -> [int] {
        return [self.x - 14, self.y - 10, self.outer_w() + 28, self.outer_h() + 26]
    }

    fn contains(self, x: int, y: int) -> bool {
        return x >= self.x && y >= self.y && x < self.x + self.outer_w() && y < self.y + self.outer_h()
    }
}

// An app the launcher and the desktop offer.
struct Launcher {
    name: str,
    icon: str,                // a symbol drawn on its tile
    color: int,
    open: fn(),
}

struct Desktop {
    screen: gfx.Surface,
    back: gfx.Surface,
    wallpaper: gfx.Surface,
    cursor: gfx.Surface,
    inp: input.Input,
    width: int,
    height: int,
    windows: [Window] = [],
    launchers: [Launcher] = [],
    next_id: int = 1,
    focus: int = 0,           // the focused window's id (0: none)
    damage: [[int]] = [],
    px: int = 0,              // the pointer
    py: int = 0,
    dragging: int = 0,        // moving a window (its id) by its title bar
    resizing: int = 0,
    grab_x: int = 0,
    grab_y: int = 0,
    captured: int = 0,        // a button went down in this window's content: it gets the pointer until up
    hover_win: int = 0,       // the window whose content the pointer is over
    menu: bool = false,       // the launcher menu is open
    last_click: int = 0,
    last_click_x: int = 0,
    last_click_y: int = 0,
    last_frame: int = 0,
    clock: str = "",
    frames: int = 0,
    busy_ms: int = 0,         // time spent in frames (for the monitor)
    selected_icon: int = -1,
    on_shutdown: fn() = () => {},
    on_logout: fn() = () => {},
    session: str = "",            // who is logged in (shown in the menu)
    overlay: App? = none,         // a full-screen app over everything (the login screen)
    ov: gfx.Surface? = none,

    // ---- windows ----

    // Open a window with `w` x `h` pixels of content.
    fn open(self, title: str, icon: str, color: int, w: int, h: int, app: App) -> Window {
        let n = self.windows.len()
        let x = min(150 + (n % 7) * 34 + (self.next_id % 3) * 12, max(self.width - w - 10, 0))
        let y = min(48 + (n % 7) * 30, max(self.height - TASKBAR_H - h - TITLE_H - 10, 0))
        let win = Window { id: self.next_id, title, icon, color, x, y, w, h, app, surface: gfx.surface(w, h) }
        self.next_id += 1
        self.windows.push(win)
        self.focus_window(win.id)
        self.menu_close()
        return win
    }

    fn find(self, id: int) -> Window? {
        return self.windows.find(w => w.id == id)
    }

    fn close(self, id: int) {
        if let w = self.find(id) {
            w.app.close()
            self.hurt(w.area())
            self.windows = self.windows.filter(x => x.id != id)
            if self.focus == id {
                self.focus = 0
                // the next window from the top that isn't minimized
                for x in self.windows {
                    if !x.minimized { self.focus = x.id }
                }
                if self.focus != 0 { self.hurt_window(self.focus) }
            }
            if self.captured == id { self.captured = 0 }
            if self.hover_win == id { self.hover_win = 0 }
            self.hurt_taskbar()
        }
    }

    // Bring a window to the front and give it the keyboard.
    fn focus_window(self, id: int) {
        if let w = self.find(id) {
            let old = self.focus
            w.minimized = false
            self.windows = self.windows.filter(x => x.id != id)
            self.windows.push(w)
            self.focus = id
            self.hurt(w.area())
            if old != id && old != 0 { self.hurt_window(old) }
            self.hurt_taskbar()
        }
    }

    fn minimize(self, id: int) {
        if let w = self.find(id) {
            w.minimized = true
            self.hurt(w.area())
            if self.focus == id {
                self.focus = 0
                for x in self.windows {
                    if !x.minimized { self.focus = x.id }
                }
                if self.focus != 0 { self.hurt_window(self.focus) }
            }
            self.hurt_taskbar()
        }
    }

    fn toggle_maximize(self, w: Window) {
        self.hurt(w.area())
        if w.maximized {
            self.place(w, w.saved[0], w.saved[1], w.saved[2], w.saved[3])
            w.maximized = false
        } else {
            w.saved = [w.x, w.y, w.w, w.h]
            self.place(w, 0, 0, self.width - 2, self.height - TASKBAR_H - TITLE_H - 1)
            w.maximized = true
        }
        self.hurt(w.area())
    }

    fn place(self, w: Window, x: int, y: int, cw: int, ch: int) {
        w.x = x
        w.y = y
        if cw != w.w || ch != w.h {
            w.w = cw
            w.h = ch
            w.surface = gfx.surface(cw, ch)
            w.dirty = true
        }
    }

    // ---- damage: the parts of the screen to redo ----

    fn hurt(self, r: [int]) {
        let x0 = max(r[0], 0)
        let y0 = max(r[1], 0)
        let x1 = min(r[0] + r[2], self.width)
        let y1 = min(r[1] + r[3], self.height)
        if x1 <= x0 || y1 <= y0 { return }
        self.damage.push([x0, y0, x1 - x0, y1 - y0])
        if self.damage.len() > 24 {
            // too many pieces: one rectangle around them all
            var a = [self.width, self.height, 0, 0]
            for d in self.damage {
                a = [min(a[0], d[0]), min(a[1], d[1]), max(a[2], d[0] + d[2]), max(a[3], d[1] + d[3])]
            }
            self.damage = [[a[0], a[1], a[2] - a[0], a[3] - a[1]]]
        }
    }

    fn hurt_window(self, id: int) {
        if let w = self.find(id) { self.hurt(w.area()) }
    }

    fn hurt_taskbar(self) {
        self.hurt([0, self.height - TASKBAR_H, self.width, TASKBAR_H])
    }

    fn hurt_all(self) {
        self.damage = [[0, 0, self.width, self.height]]
    }

    // ---- one frame ----

    // Cover the screen with `app` (everything else waits behind it), or uncover it (none).
    fn cover(self, app: App?) {
        self.overlay = app
        if app.is_some() && self.ov.is_none() { self.ov = some(gfx.surface(self.width, self.height)) }
        self.menu = false
        self.captured = 0
        self.dragging = 0
        self.resizing = 0
        self.hurt_all()
    }

    fn frame(self) {
        let start = kernel.uptime()
        let dt = if self.last_frame == 0 { 16 } else { start - self.last_frame }
        self.last_frame = start
        for e in self.inp.poll() { self.handle(e) }
        let signals = kernel_ui_dirty()
        if let o = self.overlay {
            if let ov = self.ov {
                if o.tick(Tick { dt, now: start, signals, focused: true }) {
                    o.paint(ov)
                    self.hurt_all()
                }
            }
            self.compose()
            self.frames += 1
            return
        }
        for w in self.windows {
            let t = Tick { dt, now: start, signals, focused: w.id == self.focus }
            if w.app.tick(t) { w.dirty = true }
            if w.dirty && !w.minimized {
                w.app.paint(w.surface)
                w.dirty = false
                self.hurt([w.content_x(), w.content_y(), w.w, w.h])
            }
        }
        let c = clock_text()
        if c != self.clock {
            self.clock = c
            self.hurt([self.width - 220, self.height - TASKBAR_H, 220, TASKBAR_H])
        }
        self.compose()
        self.frames += 1
        self.busy_ms += kernel.uptime() - start
    }

    // ---- input ----

    fn handle(self, e: input.Event) {
        if let o = self.overlay {
            if e.kind != "key" {
                let ox = self.px
                let oy = self.py
                self.px = e.x
                self.py = e.y
                self.hurt([ox - 2, oy - 2, 18, 24])
                self.hurt([self.px - 2, self.py - 2, 18, 24])
            }
            if e.kind == "key" { o.key(e) } else { o.mouse(e) }
            return
        }
        if e.kind == "key" {
            self.key(e)
            return
        }
        let ox = self.px
        let oy = self.py
        self.px = e.x
        self.py = e.y
        if ox != self.px || oy != self.py {
            self.hurt([ox - 2, oy - 2, 18, 24])
            self.hurt([self.px - 2, self.py - 2, 18, 24])
            self.pointer_moved()
        }
        if e.kind == "button" {
            if e.down { self.press(e) } else { self.release(e) }
        } else if e.kind == "wheel" {
            if let w = self.window_at(e.x, e.y) {
                w.app.mouse(self.local(w, e))
            }
        }
    }

    fn key(self, e: input.Event) {
        if e.down && e.alt && e.key == "Tab" {
            // the next window to the front
            if self.windows.len() > 1 { self.focus_window(self.windows[0].id) }
            return
        }
        if e.down && e.alt && e.key == "F4" {
            if self.focus != 0 { self.close(self.focus) }
            return
        }
        if e.down && e.key == "Meta" {
            if self.menu { self.menu_close() } else { self.menu_open() }
            return
        }
        if self.menu && e.down && e.key == "Escape" {
            self.menu_close()
            return
        }
        if let w = self.find(self.focus) {
            w.app.key(e)
        }
    }

    fn pointer_moved(self) {
        if self.dragging != 0 {
            if let w = self.find(self.dragging) {
                self.hurt(w.area())
                w.x = self.px - self.grab_x
                w.y = max(self.py - self.grab_y, 0)
                self.hurt(w.area())
            }
            return
        }
        if self.resizing != 0 {
            if let w = self.find(self.resizing) {
                self.hurt(w.area())
                self.place(w, w.x, w.y, max(self.px - w.x + self.grab_x, 220), max(self.py - w.y - TITLE_H + self.grab_y, 120))
                self.hurt(w.area())
            }
            return
        }
        // hover: the title bar buttons, taskbar and menu items light up
        self.hurt_chrome_hover()
        let e = input.Event { kind: "move", x: self.px, y: self.py }
        if self.captured != 0 {
            if let w = self.find(self.captured) { w.app.mouse(self.local(w, e)) }
            return
        }
        let over = self.window_at(self.px, self.py)
        let id = if let w = over { w.id } else { 0 }
        if id != self.hover_win {
            if let old = self.find(self.hover_win) {
                old.app.mouse(input.Event { kind: "leave", x: -1, y: -1 })
            }
            self.hover_win = id
        }
        if let w = over {
            if self.py >= w.content_y() { w.app.mouse(self.local(w, e)) }
        }
    }

    // the pointer's area of interest changed: redo the bits that show hover
    fn hurt_chrome_hover(self) {
        if self.py >= self.height - TASKBAR_H - 4 || self.menu { self.hurt_taskbar() }
        if self.menu { self.hurt(self.menu_rect()) }
        for w in self.windows {
            if !w.minimized && self.py < w.content_y() + 4 && self.py > w.y - 30 {
                self.hurt([w.x + w.outer_w() - 100, w.y, 100, TITLE_H])
            }
        }
        if self.px < self.icons_w() + 20 { self.hurt([0, 0, self.icons_w(), self.height - TASKBAR_H]) }
    }

    fn press(self, e: input.Event) {
        let double = kernel.uptime() - self.last_click < 400 && abs(e.x - self.last_click_x) < 6 && abs(e.y - self.last_click_y) < 6
        self.last_click = if double { 0 } else { kernel.uptime() }
        self.last_click_x = e.x
        self.last_click_y = e.y
        if self.menu {
            if self.menu_click(e.x, e.y) { return }
            self.menu_close()
            if e.y >= self.height - TASKBAR_H && e.x < 124 { return }
        }
        if e.y >= self.height - TASKBAR_H {
            self.taskbar_click(e.x)
            return
        }
        if let w = self.window_at(e.x, e.y) {
            if w.id != self.focus { self.focus_window(w.id) }
            let rx = e.x - w.x
            let ry = e.y - w.y
            if ry < TITLE_H {
                let from_right = w.outer_w() - rx
                if e.button == 0 && from_right <= 32 {
                    self.close(w.id)
                } else if e.button == 0 && from_right <= 62 && w.resizable {
                    self.toggle_maximize(w)
                } else if e.button == 0 && from_right <= 92 {
                    self.minimize(w.id)
                } else if double && w.resizable {
                    self.toggle_maximize(w)
                } else {
                    self.dragging = w.id
                    self.grab_x = rx
                    self.grab_y = ry
                }
                return
            }
            if w.resizable && rx >= w.outer_w() - 14 && ry >= w.outer_h() - 14 {
                self.resizing = w.id
                self.grab_x = w.outer_w() - rx
                self.grab_y = w.outer_h() - ry
                return
            }
            self.captured = w.id
            w.app.mouse(self.local(w, e))
            return
        }
        // the desktop: its icons open with a double click
        let i = self.icon_at(e.x, e.y)
        if i != self.selected_icon {
            self.selected_icon = i
            self.hurt([0, 0, self.icons_w(), self.height - TASKBAR_H])
        }
        if i >= 0 && double {
            self.launchers[i].open()
        }
    }

    fn release(self, e: input.Event) {
        if self.dragging != 0 || self.resizing != 0 {
            self.dragging = 0
            self.resizing = 0
            return
        }
        if self.captured != 0 {
            if let w = self.find(self.captured) { w.app.mouse(self.local(w, e)) }
            self.captured = 0
        }
    }

    // an event with the position in `w`'s content coordinates
    fn local(self, w: Window, e: input.Event) -> input.Event {
        return input.Event { kind: e.kind, x: e.x - w.content_x(), y: e.y - w.content_y(), button: e.button, down: e.down,
            delta: e.delta, ctrl: e.ctrl, shift: e.shift, alt: e.alt }
    }

    // the topmost window under a point
    fn window_at(self, x: int, y: int) -> Window? {
        var found: Window? = none
        for w in self.windows {
            if !w.minimized && w.contains(x, y) { found = some(w) }
        }
        return found
    }

    // ---- taskbar and launcher ----

    fn taskbar_click(self, x: int) {
        if x < 124 {
            if self.menu { self.menu_close() } else { self.menu_open() }
            return
        }
        let bw = self.task_w()
        for i, w in self.windows {
            let bx = 132 + i * (bw + 6)
            if x >= bx && x < bx + bw {
                if w.id == self.focus && !w.minimized {
                    self.minimize(w.id)
                } else {
                    self.focus_window(w.id)
                }
                return
            }
        }
    }

    // the width of a window's taskbar button: narrower when there are many
    fn task_w(self) -> int {
        let room = self.width - 132 - 200
        return min(166, room / max(self.windows.len(), 1) - 6)
    }

    fn menu_open(self) {
        self.menu = true
        self.hurt(self.menu_rect())
        self.hurt_taskbar()
    }

    fn menu_close(self) {
        if !self.menu { return }
        self.menu = false
        self.hurt(self.menu_rect())
        self.hurt_taskbar()
    }

    fn menu_rect(self) -> [int] {
        let h = 64 + self.launchers.len() * 40 + 52
        return [8, self.height - TASKBAR_H - h - 8, 260, h]
    }

    // returns whether the click was in the menu
    fn menu_click(self, x: int, y: int) -> bool {
        let r = self.menu_rect()
        if x < r[0] || y < r[1] || x >= r[0] + r[2] || y >= r[1] + r[3] { return false }
        let i = (y - r[1] - 56) / 40
        if y >= r[1] + 56 && i >= 0 && i < self.launchers.len() {
            self.menu_close()
            self.launchers[i].open()
        } else if y >= r[1] + r[3] - 46 {
            self.menu_close()
            if x < r[0] + r[2] / 2 { self.on_logout() } else { self.on_shutdown() }
        }
        return true
    }

    // where desktop icon i goes: top to bottom, then the next column
    fn icon_pos(self, i: int) -> [int] {
        let per = max((self.height - TASKBAR_H - 24) / 92, 1)
        return [26 + (i / per) * 92, 20 + (i % per) * 92]
    }

    // how wide the icon area is
    fn icons_w(self) -> int {
        if self.launchers.is_empty() { return 0 }
        return self.icon_pos(self.launchers.len() - 1)[0] + 84
    }

    // the desktop icon under a point, or -1
    fn icon_at(self, x: int, y: int) -> int {
        for i in 0..self.launchers.len() {
            let p = self.icon_pos(i)
            if x >= p[0] - 14 && x < p[0] + 70 && y >= p[1] - 6 && y < p[1] + 86 { return i }
        }
        return -1
    }

    // ---- drawing ----

    fn compose(self) {
        if self.damage.is_empty() { return }
        let b = self.back
        if let ov = self.ov {
            if self.overlay.is_some() {
                for r in self.damage {
                    b.clip(r[0], r[1], r[2], r[3])
                    b.draw(ov, 0, 0)
                    b.sprite(self.cursor, self.px - 1, self.py - 1, 1)
                    self.screen.clip(r[0], r[1], r[2], r[3])
                    self.screen.draw(b, 0, 0)
                }
                b.unclip()
                self.screen.unclip()
                self.damage = []
                return
            }
        }
        for r in self.damage {
            b.clip(r[0], r[1], r[2], r[3])
            b.draw(self.wallpaper, 0, 0)
            self.draw_icons(r)
            for w in self.windows {
                if !w.minimized && overlaps(w.area(), r) { self.draw_window(w) }
            }
            if r[1] + r[3] > self.height - TASKBAR_H { self.draw_taskbar() }
            if self.menu && overlaps(self.menu_rect(), r) { self.draw_menu() }
            b.sprite(self.cursor, self.px - 1, self.py - 1, 1)
            self.screen.clip(r[0], r[1], r[2], r[3])
            self.screen.draw(b, 0, 0)
        }
        b.unclip()
        self.screen.unclip()
        self.damage = []
    }

    fn draw_icons(self, r: [int]) {
        if r[0] > self.icons_w() { return }
        let b = self.back
        for i, l in self.launchers {
            let p = self.icon_pos(i)
            let ix = p[0]
            let iy = p[1]
            let hover = self.icon_at(self.px, self.py) == i && self.dragging == 0
            if i == self.selected_icon {
                b.round_shade(ix - 14, iy - 6, 84, 92, 10, 0xffffff, 46)
            } else if hover {
                b.round_shade(ix - 14, iy - 6, 84, 92, 10, 0xffffff, 22)
            }
            tile(b, ix + 4, iy, 48, l.icon, l.color)
            let label = fit(l.name, gfx.UI_BOLD, 84)
            let tw = gfx.text_width(label, gfx.UI_BOLD)
            b.text(ix + 28 - tw / 2 + 1, iy + 59, label, 0x000000, gfx.UI_BOLD)
            b.text(ix + 28 - tw / 2, iy + 58, label, 0xffffff, gfx.UI_BOLD)
        }
    }

    fn draw_window(self, w: Window) {
        let b = self.back
        let focused = w.id == self.focus
        let ow = w.outer_w()
        let oh = w.outer_h()
        // a soft shadow: layers of see-through dark
        let depth = if focused { 9 } else { 5 }
        for i in 0..depth {
            b.round_shade(w.x - i, w.y - i + 5, ow + 2 * i, oh + 2 * i, RADIUS + i, 0x000000, if focused { 13 } else { 11 })
        }
        b.round(w.x, w.y, ow, oh, RADIUS, if focused { 0x8a86a0 } else { 0xb4b2c2 })
        b.round(w.x + 1, w.y + 1, ow - 2, oh - 2, RADIUS - 1, if focused { 0xf1effa } else { 0xf7f7fa })
        // title bar: the app's color as a stripe, the icon, the title
        b.round(w.x + 10, w.y + 8, 15, 15, 4, w.color)
        b.text_in(w.x + 10, w.y + 8, 15, 15, w.icon, 0xffffff, gfx.UI_BOLD)
        let tf = if focused { gfx.UI_BOLD } else { gfx.UI }
        b.text(w.x + 33, w.y + (TITLE_H - gfx.line_height(tf)) / 2, fit(w.title, tf, ow - 140), if focused { 0x23212e } else { 0x8c8a98 }, tf)
        // buttons: minimize, maximize, close
        let over_title = self.py >= w.y && self.py < w.y + TITLE_H && self.dragging == 0
        let names = ["—", "□", "✕"]
        for k in 0..3 {
            if k == 1 && !w.resizable { continue }
            let bx = w.x + ow - 92 + k * 30
            let hot = over_title && self.px >= bx && self.px < bx + 30 && self.top_at(self.px, self.py) == w.id
            if hot {
                b.round(bx + 2, w.y + 4, 26, TITLE_H - 8, 6, if k == 2 { 0xe5484d } else { 0xdcd9e8 })
            }
            let color = if hot && k == 2 { 0xffffff } else if focused { 0x4a4757 } else { 0xa9a7b5 }
            b.text_in(bx, w.y + 1, 30, TITLE_H - 2, names[k], color, gfx.UI)
        }
        // the content
        b.draw(w.surface, w.content_x(), w.content_y())
        if w.resizable && !w.maximized {
            // the grip
            for k in 0..3 {
                b.shade(w.x + ow - 5 - k * 4, w.y + oh - 5, 2, 2, 0x000000, 70)
                b.shade(w.x + ow - 5, w.y + oh - 5 - k * 4, 2, 2, 0x000000, 70)
            }
        }
    }

    // the id of the topmost window at a point (0: none)
    fn top_at(self, x: int, y: int) -> int {
        if let w = self.window_at(x, y) { return w.id }
        return 0
    }

    fn draw_taskbar(self) {
        let b = self.back
        let y = self.height - TASKBAR_H
        b.shade(0, y, self.width, TASKBAR_H, 0x0d0b18, 215)
        b.shade(0, y, self.width, 1, 0xffffff, 28)
        // the start button
        let hot = self.py >= y && self.px < 124
        if self.menu || hot { b.round_shade(6, y + 5, 114, 30, 8, 0xffffff, if self.menu { 50 } else { 28 }) }
        b.text(18, y + 9, "✦", 0xb9a8ff, gfx.TEXT_BOLD)
        b.text(38, y + 12, "StellaOS", 0xffffff, gfx.UI_BOLD)
        // one button per window
        let bw = self.task_w()
        for i, w in self.windows {
            let bx = 132 + i * (bw + 6)
            let focused = w.id == self.focus && !w.minimized
            let over = self.py >= y && self.px >= bx && self.px < bx + bw
            b.round_shade(bx, y + 5, bw, 30, 8, 0xffffff, if focused { 44 } else if over { 30 } else { 14 })
            if focused { b.round(bx + bw / 2 - 23, y + 33, 46, 3, 1, 0xb9a8ff) }
            b.round(bx + 8, y + 12, 16, 16, 4, w.color)
            b.text_in(bx + 8, y + 12, 16, 16, w.icon, 0xffffff, gfx.UI_BOLD)
            b.text(bx + 32, y + 12, fit(w.title, gfx.UI, bw - 40), if w.minimized { 0x9a97ad } else { 0xffffff }, gfx.UI)
        }
        // the clock
        let cw = gfx.text_width(self.clock, gfx.UI_BOLD)
        b.text(self.width - cw - 16, y + 12, self.clock, 0xffffff, gfx.UI_BOLD)
    }

    fn draw_menu(self) {
        let b = self.back
        let r = self.menu_rect()
        for i in 0..8 {
            b.round_shade(r[0] - i, r[1] - i + 4, r[2] + 2 * i, r[3] + 2 * i, 12 + i, 0x000000, 12)
        }
        b.round(r[0], r[1], r[2], r[3], 12, 0x3b3650)
        b.round(r[0] + 1, r[1] + 1, r[2] - 2, r[3] - 2, 11, 0x1c1929)
        b.text(r[0] + 18, r[1] + 14, "✦ StellaOS", 0xffffff, gfx.TEXT_BOLD)
        if self.session != "" {
            let who = fit(self.session, gfx.UI, 110)
            b.text(r[0] + r[2] - 18 - gfx.text_width(who, gfx.UI), r[1] + 17, who, 0xb8b2e0, gfx.UI)
        }
        b.text(r[0] + 20, r[1] + 36, "Apps", 0x8d88a8, gfx.UI)
        for i, l in self.launchers {
            let iy = r[1] + 56 + i * 40
            let over = self.px >= r[0] && self.px < r[0] + r[2] && self.py >= iy && self.py < iy + 40
            if over { b.round_shade(r[0] + 8, iy + 2, r[2] - 16, 36, 8, 0xffffff, 30) }
            tile(b, r[0] + 18, iy + 6, 28, l.icon, l.color)
            b.text(r[0] + 58, iy + 12, l.name, 0xffffff, gfx.UI)
        }
        let sy = r[1] + r[3] - 46
        b.shade(r[0] + 12, sy, r[2] - 24, 1, 0xffffff, 30)
        let half = r[2] / 2
        let in_row = self.py >= sy && self.py < r[1] + r[3]
        // log out (left)
        let over_out = in_row && self.px >= r[0] && self.px < r[0] + half
        if over_out { b.round_shade(r[0] + 8, sy + 6, half - 12, 34, 8, 0xffffff, 30) }
        b.text(r[0] + 20, sy + 13, "←", 0xffffff, gfx.TEXT)
        b.text(r[0] + 42, sy + 14, "Log out", 0xffffff, gfx.UI)
        // shut down (right)
        let over = in_row && self.px >= r[0] + half && self.px < r[0] + r[2]
        let x0 = r[0] + half - 4
        if over { b.round_shade(x0 + 8, sy + 6, half - 12, 34, 8, 0xe5484d, 120) }
        b.circle(x0 + 28, sy + 23, 7, 0xffffff)
        b.circle(x0 + 28, sy + 23, 5, if over { gfx.mix(0x1c1929, 0xe5484d, 120, 255) } else { 0x1c1929 })
        b.rect(x0 + 26, sy + 13, 4, 8, if over { gfx.mix(0x1c1929, 0xe5484d, 120, 255) } else { 0x1c1929 })
        b.rect(x0 + 27, sy + 14, 2, 8, 0xffffff)
        b.text(x0 + 44, sy + 14, "Shut down", 0xffffff, gfx.UI)
    }
}

// a rounded square with a symbol: an app's icon
fn tile(b: gfx.Surface, x: int, y: int, size: int, icon: str, color: int) {
    b.round_shade(x, y + 2, size, size, size / 4, 0x000000, 50)
    b.round(x, y, size, size, size / 4, color)
    let face = if size >= 40 { gfx.TITLE } else { gfx.UI_BOLD }
    b.text_in(x, y, size, size, icon, 0xffffff, face)
}

fn overlaps(a: [int], b: [int]) -> bool {
    return a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}

// `s` cut to `width` pixels, with "…" when it doesn't fit
fn fit(s: str, face: int, width: int) -> str {
    if gfx.text_width(s, face) <= width { return s }
    var cs = s.chars()
    while !cs.is_empty() && gfx.text_width(cs.join("") + "…", face) > width { cs.pop() }
    return cs.join("") + "…"
}

fn clock_text() -> str {
    let d = kernel.date(kernel.time_ms())
    return "${kernel.WEEKDAYS[d.weekday]} ${d.day} ${kernel.MONTHS[d.month - 1]}   ${kernel.two(d.hour)}:${kernel.two(d.minute)}"
}

extern fn st_k_ui_dirty() -> bool

fn kernel_ui_dirty() -> bool {
    return st_k_ui_dirty()
}

// The wallpaper: a night sky.
fn wallpaper(w: int, h: int) -> gfx.Surface {
    let s = gfx.surface(w, h)
    s.gradient(0, 0, w, h, 0x241a52, 0x0b0b1a)
    // a glow low on the right
    for i in 0..14 {
        s.circle_shade(w * 3 / 4, h + 120, 520 - i * 30, 0x7c5cff, 7)
    }
    // stars, from a fixed seed so every boot looks the same
    var seed = 12345
    for i in 0..220 {
        seed = (seed * 1103515245 + 12345) % 2147483648
        let x = seed % w
        seed = (seed * 1103515245 + 12345) % 2147483648
        let y = seed % (h - TASKBAR_H)
        seed = (seed * 1103515245 + 12345) % 2147483648
        let bright = 60 + seed % 160
        if seed % 17 == 0 {
            s.circle_shade(x, y, 2, 0xffffff, bright)
        } else {
            s.shade(x, y, 1, 1, 0xffffff, bright)
        }
    }
    let label = "✦ StellaOS"
    let lw = gfx.text_width(label, gfx.BIG)
    s.text(w - lw - 40, h - TASKBAR_H - 70, label, gfx.mix(0x241a52, 0xffffff, 1, 6), gfx.BIG)
    return s
}

// the mouse pointer: an arrow
fn arrow() -> gfx.Surface {
    return gfx.sprite([
        "#",
        "##",
        "#o#",
        "#oo#",
        "#ooo#",
        "#oooo#",
        "#ooooo#",
        "#oooooo#",
        "#ooooooo#",
        "#oooooooo#",
        "#ooooo####",
        "#oo#oo#",
        "#o# #oo#",
        "##  #oo#",
        "#    #oo#",
        "     #oo#",
        "      ##",
    ], {"#": 0x111111, "o": 0xffffff})
}

// Take over the display, keyboard and mouse. Fails without a display (`stellang boot --gui`).
fn start(width: int, height: int) -> Desktop! {
    let screen = display.open(width, height)?
    let d = Desktop {
        screen,
        back: gfx.surface(width, height),
        wallpaper: wallpaper(width, height),
        cursor: arrow(),
        inp: input.open(width, height),
        width,
        height,
        px: width / 2,
        py: height / 2,
    }
    d.clock = clock_text()
    d.hurt_all()
    d.compose()
    return d
}
