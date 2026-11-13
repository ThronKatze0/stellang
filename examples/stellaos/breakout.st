// Bricks: knock out every brick with the ball. Move the paddle with the mouse or the arrow keys;
// click or Space launches the ball.

import gfx
import input
import wm
import game

const W = 480
const H = 400
const TOP = 36
const PADDLE_W = 76
const PADDLE_Y = H - 30
const ROWS_OF_BRICKS = 6
const BRICK_COLS = 10
const BRICK_W = 44
const BRICK_H = 16
const COLORS = [0xff6b81, 0xff9f43, 0xfeca57, 0x1dd1a1, 0x54a0ff, 0xa29bfe]

// positions are in 1/100 pixels, so slow speeds still move smoothly
struct Breakout {
    px: int = W / 2,                  // paddle center (pixels)
    bx: int = 0,
    by: int = 0,
    vx: int = 0,
    vy: int = 0,
    stuck: bool = true,               // the ball rides the paddle until launched
    bricks: [int] = [],               // hits left per brick (0 = gone)
    score: int = 0,
    lives: int = 3,
    level: int = 1,
    state: str = "playing",           // playing, over, won
    keys: game.Keys = game.Keys {},
    sparks: [[int]] = [],             // x, y, color, age

    fn reset_level(self) {
        self.bricks = []
        for r in 0..ROWS_OF_BRICKS {
            for c in 0..BRICK_COLS { self.bricks.push(if r < self.level - 1 { 2 } else { 1 }) }
        }
        self.stuck = true
    }

    fn launch(self) {
        if self.state != "playing" {
            self.score = 0
            self.lives = 3
            self.level = 1
            self.state = "playing"
            self.reset_level()
            return
        }
        if self.stuck {
            self.stuck = false
            let speed = 330 + self.level * 40
            self.vx = speed * 2 / 3
            self.vy = -speed
        }
    }

    fn tick(self, t: wm.Tick) -> bool {
        for k in self.keys.take() {
            if k == " " || k == "Enter" { self.launch() }
        }
        let dt = min(t.dt, 40)
        if self.keys.down("ArrowLeft") || self.keys.down("a") { self.px -= dt * 6 / 10 }
        if self.keys.down("ArrowRight") || self.keys.down("d") { self.px += dt * 6 / 10 }
        self.px = min(max(self.px, PADDLE_W / 2), W - PADDLE_W / 2)
        self.sparks = self.sparks.filter(sp => sp[3] < 400)
        for sp in self.sparks { sp[3] += dt }
        if self.state != "playing" { return true }
        if self.stuck {
            self.bx = self.px * 100
            self.by = (PADDLE_Y - 7) * 100
            return true
        }
        // move in small steps so the ball can't skip through a brick
        let steps = 4
        for i in 0..steps { self.move(dt * 100 / steps) }
        return true
    }

    // advance `ms` (x100) milliseconds
    fn move(self, ms: int) {
        self.bx += self.vx * ms / 100000
        self.by += self.vy * ms / 100000
        let x = self.bx / 100
        let y = self.by / 100
        if x < 6 {
            self.bx = 600
            self.vx = abs(self.vx)
        }
        if x > W - 6 {
            self.bx = (W - 6) * 100
            self.vx = -abs(self.vx)
        }
        if y < TOP + 6 {
            self.by = (TOP + 6) * 100
            self.vy = abs(self.vy)
        }
        // the paddle: where it hits decides the angle
        if self.vy > 0 && y >= PADDLE_Y - 6 && y <= PADDLE_Y + 4 && abs(x - self.px) <= PADDLE_W / 2 + 4 {
            let speed = 330 + self.level * 40 + self.score / 20
            let off = (x - self.px) * 100 / (PADDLE_W / 2)      // -100 .. 100
            self.vx = speed * off / 110
            self.vy = -max(speed - abs(self.vx) / 3, 160)
        }
        if y > H + 10 {
            self.lives -= 1
            self.stuck = true
            if self.lives <= 0 { self.state = "over" }
            return
        }
        // bricks
        let c = (x - brick_x0()) / BRICK_W
        let r = (y - TOP - 30) / BRICK_H
        if x >= brick_x0() && c >= 0 && c < BRICK_COLS && r >= 0 && r < ROWS_OF_BRICKS && y >= TOP + 30 {
            let i = r * BRICK_COLS + c
            if self.bricks[i] > 0 {
                self.bricks[i] -= 1
                self.vy = -self.vy
                self.score += 10
                self.sparks.push([x, y, COLORS[r], 0])
                if !self.bricks.any(b => b > 0) {
                    self.level += 1
                    if self.level > 4 {
                        self.state = "won"
                    } else {
                        self.reset_level()
                    }
                }
            }
        }
    }

    fn paint(self, s: gfx.Surface) {
        s.gradient(0, 0, W, H, 0x1b1d3a, 0x0e0f1f)
        s.shade(0, 0, W, TOP, 0x000000, 90)
        s.text(14, 9, "Score ${self.score}", 0xffffff, gfx.TEXT_BOLD)
        s.text(W / 2 - 30, 11, "Level ${self.level}", 0xa4a8d8, gfx.UI_BOLD)
        for i in 0..self.lives { s.text(W - 24 - i * 20, 9, "♥", 0xff6b81, gfx.TEXT_BOLD) }
        for r in 0..ROWS_OF_BRICKS {
            for c in 0..BRICK_COLS {
                let hits = self.bricks[r * BRICK_COLS + c]
                if hits == 0 { continue }
                let x = brick_x0() + c * BRICK_W
                let y = TOP + 30 + r * BRICK_H
                let color = if hits > 1 { gfx.tint(COLORS[r], -60) } else { COLORS[r] }
                s.round(x + 1, y + 1, BRICK_W - 2, BRICK_H - 2, 3, color)
                s.shade(x + 3, y + 2, BRICK_W - 6, 3, 0xffffff, 60)
            }
        }
        for sp in self.sparks {
            let a = 200 - sp[3] / 2
            s.circle_shade(sp[0], sp[1], 4 + sp[3] / 25, sp[2], max(a, 0))
        }
        s.round(self.px - PADDLE_W / 2, PADDLE_Y, PADDLE_W, 10, 5, 0xdfe4ff)
        s.shade(self.px - PADDLE_W / 2 + 4, PADDLE_Y + 2, PADDLE_W - 8, 2, 0xffffff, 120)
        s.circle_shade(self.bx / 100, self.by / 100, 11, 0xffffff, 40)
        s.circle(self.bx / 100, self.by / 100, 6, 0xffffff)
        if self.state != "playing" || (self.stuck && self.lives == 3 && self.score == 0) {
            if self.state != "playing" { s.shade(0, TOP, W, H - TOP, 0x000000, 140) }
            let title = if self.state == "over" { "Game over" } else if self.state == "won" { "You won!" } else { "" }
            if title != "" { s.text_in(0, 170, W, 50, title, 0xffffff, gfx.BIG) }
            let hint = if self.state == "playing" { "Click or Space to launch" } else { "Click to play again" }
            s.text_in(0, 240, W, 24, hint, 0xc8cbf0, gfx.TEXT)
        }
    }
}

fn brick_x0() -> int {
    return (W - BRICK_COLS * BRICK_W) / 2
}

fn open(d: wm.Desktop) {
    let g = Breakout {}
    g.reset_level()
    let w = d.open("Bricks", "B", 0xff9f43, W, H, wm.App {
        tick: (t: wm.Tick) => g.tick(t),
        paint: (s: gfx.Surface) => g.paint(s),
        key: (e: input.Event) => g.keys.handle(e),
        mouse: (e: input.Event) => {
            if e.kind == "move" && e.x >= 0 { g.px = e.x }
            if e.kind == "button" && e.down { g.launch() }
        },
    })
    w.resizable = false
}
