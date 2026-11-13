// Snake: eat, grow, don't bite yourself. Arrow keys or WASD, Space pauses and restarts.

import gfx
import input
import wm
import game

const COLS = 24
const ROWS = 18
const CELL = 18
const TOP = 40
const W = COLS * CELL
const H = ROWS * CELL + TOP

struct Snake {
    body: [[int]] = [],       // head first
    dir: [int] = [1, 0],
    queued: [[int]] = [],     // turns typed faster than the snake moves
    food: [int] = [0, 0],
    score: int = 0,
    best: int = 0,
    state: str = "ready",     // ready, playing, paused, over
    clock: game.Clock = game.Clock { every: 120 },
    rng: game.Rng = game.rng(),
    keys: game.Keys = game.Keys {},
    t: int = 0,

    fn reset(self) {
        self.body = [[8, 9], [7, 9], [6, 9], [5, 9]]
        self.dir = [1, 0]
        self.queued = []
        self.score = 0
        self.clock.every = 120
        self.place_food()
    }

    fn place_food(self) {
        while true {
            let f = [self.rng.below(COLS), self.rng.below(ROWS)]
            if !self.body.any(p => p[0] == f[0] && p[1] == f[1]) {
                self.food = f
                return
            }
        }
    }

    fn tick(self, t: wm.Tick) -> bool {
        self.t += t.dt
        for k in self.keys.take() { self.press(k) }
        if self.state != "playing" { return true }
        for i in 0..self.clock.steps(t.dt) { self.step() }
        return true
    }

    fn press(self, k: str) {
        if k == " " || k == "Enter" {
            if self.state == "playing" {
                self.state = "paused"
            } else {
                if self.state != "paused" { self.reset() }
                self.state = "playing"
            }
            return
        }
        var d: [int] = []
        if k == "ArrowUp" || k == "w" { d = [0, -1] }
        if k == "ArrowDown" || k == "s" { d = [0, 1] }
        if k == "ArrowLeft" || k == "a" { d = [-1, 0] }
        if k == "ArrowRight" || k == "d" { d = [1, 0] }
        if d.is_empty() { return }
        if self.state == "ready" || self.state == "over" {
            self.reset()
            self.state = "playing"
        }
        let last = if self.queued.is_empty() { self.dir } else { self.queued[self.queued.len() - 1] }
        if d[0] != -last[0] || d[1] != -last[1] { self.queued.push(d) }
    }

    fn step(self) {
        if !self.queued.is_empty() { self.dir = self.queued.remove(0) }
        let head = [self.body[0][0] + self.dir[0], self.body[0][1] + self.dir[1]]
        let hit_wall = head[0] < 0 || head[1] < 0 || head[0] >= COLS || head[1] >= ROWS
        let hit_self = self.body.slice(0, self.body.len() - 1).any(p => p[0] == head[0] && p[1] == head[1])
        if hit_wall || hit_self {
            self.state = "over"
            self.best = max(self.best, self.score)
            return
        }
        self.body.insert(0, head)
        if head[0] == self.food[0] && head[1] == self.food[1] {
            self.score += 10
            self.clock.every = max(self.clock.every - 3, 55)
            self.place_food()
        } else {
            self.body.pop()
        }
    }

    fn paint(self, s: gfx.Surface) {
        s.gradient(0, 0, W, TOP, 0x1e2a1f, 0x18221a)
        s.text(14, 9, "Score ${self.score}", 0xffffff, gfx.TEXT_BOLD)
        let best = "Best ${max(self.best, self.score)}"
        s.text(W - gfx.text_width(best, gfx.UI) - 14, 12, best, 0x9fc5a3, gfx.UI)
        // the field: a checkerboard
        for y in 0..ROWS {
            for x in 0..COLS {
                s.rect(x * CELL, TOP + y * CELL, CELL, CELL, if (x + y) % 2 == 0 { 0x2a3b2c } else { 0x263627 })
            }
        }
        // food, pulsing
        let pulse = (self.t / 90) % 6
        let fx = self.food[0] * CELL + CELL / 2
        let fy = TOP + self.food[1] * CELL + CELL / 2
        s.circle_shade(fx, fy, CELL / 2 + 2 + pulse / 2, 0xff7675, 60)
        s.circle(fx, fy, CELL / 2 - 2, 0xff5e57)
        s.circle(fx - 3, fy - 3, 2, 0xffc9c6)
        // the snake, the head brightest
        let n = self.body.len()
        var i = n - 1
        while i >= 0 {
            let p = self.body[i]
            let c = gfx.mix(0x55efc4, 0x00a37a, i, max(n, 2))
            s.round(p[0] * CELL + 1, TOP + p[1] * CELL + 1, CELL - 2, CELL - 2, 6, c)
            i -= 1
        }
        if n > 0 {
            let h = self.body[0]
            let ex = h[0] * CELL + CELL / 2 + self.dir[0] * 3
            let ey = TOP + h[1] * CELL + CELL / 2 + self.dir[1] * 3
            s.circle(ex - self.dir[1] * 4, ey - self.dir[0] * 4, 2, 0x10241a)
            s.circle(ex + self.dir[1] * 4, ey + self.dir[0] * 4, 2, 0x10241a)
        }
        if self.state != "playing" {
            s.shade(0, TOP, W, H - TOP, 0x0b120c, 150)
            let title = if self.state == "over" { "Game over" } else if self.state == "paused" { "Paused" } else { "Snake" }
            s.text_in(0, TOP + 80, W, 50, title, 0xffffff, gfx.BIG)
            let hint = if self.state == "paused" { "Space to go on" } else { "Arrow keys or Space to play" }
            s.text_in(0, TOP + 140, W, 24, hint, 0xb8d8bc, gfx.TEXT)
            if self.state == "over" {
                s.text_in(0, TOP + 170, W, 24, "${self.score} points", 0xffeaa7, gfx.TEXT_BOLD)
            }
        }
    }
}

fn open(d: wm.Desktop) {
    let g = Snake {}
    g.reset()
    let w = d.open("Snake", "S", 0x00b894, W, H, wm.App {
        tick: (t: wm.Tick) => g.tick(t),
        paint: (s: gfx.Surface) => g.paint(s),
        key: (e: input.Event) => g.keys.handle(e),
    })
    w.resizable = false
}
