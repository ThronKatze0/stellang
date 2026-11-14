// Worm: eat the apples, don't bite yourself. Arrow keys steer, Space pauses.
// Enums, structs, lists, keys, graphics and sound in one program.

enum Dir {
    Up,
    Down,
    Left,
    Right,

    fn dx(self) -> int {
        return match self {
            Left => -1,
            Right => 1,
            _ => 0,
        }
    }

    fn dy(self) -> int {
        return match self {
            Up => -1,
            Down => 1,
            _ => 0,
        }
    }

    fn opposite(self, other: Dir) -> bool {
        return self.dx() == -other.dx() && self.dy() == -other.dy()
    }
}

enum State { Playing, Paused, Over }

struct Cell {
    x: int,
    y: int,
}

const COLS = 26
const ROWS = 18
const SIZE = 20
const TOP = 36

struct Game {
    worm: [Cell] = [],
    dir: Dir = .Right,
    apple: Cell = Cell { x: 0, y: 0 },
    score: int = 0,
    best: int = 0,
    state: State = .Playing,
    speed: int = 140,

    fn reset(self) {
        self.worm = [Cell { x: 6, y: 9 }, Cell { x: 5, y: 9 }, Cell { x: 4, y: 9 }]
        self.dir = .Right
        self.score = 0
        self.speed = 140
        self.state = .Playing
        self.place_apple()
    }

    fn place_apple(self) {
        while true {
            let c = Cell { x: random(COLS), y: random(ROWS) }
            if !self.worm.contains(c) {
                self.apple = c
                return
            }
        }
    }

    fn steer(self, k: str) {
        let d = match k {
            "ArrowUp" => Dir.Up,
            "ArrowDown" => Dir.Down,
            "ArrowLeft" => Dir.Left,
            "ArrowRight" => Dir.Right,
            _ => self.dir,
        }
        if !d.opposite(self.dir) { self.dir = d }
    }

    fn step(self) {
        let head = self.worm[0]
        let next = Cell { x: head.x + self.dir.dx(), y: head.y + self.dir.dy() }
        let off = next.x < 0 || next.y < 0 || next.x >= COLS || next.y >= ROWS
        if off || self.worm.slice(0, self.worm.len() - 1).contains(next) {
            self.state = .Over
            self.best = max(self.best, self.score)
            beep(196, 300)
            return
        }
        self.worm.insert(0, next)
        if next == self.apple {
            self.score += 10
            self.speed = max(60, self.speed - 4)
            beep(880, 60)
            self.place_apple()
        } else {
            self.worm.pop()
        }
    }

    fn draw(self) {
        clear(0x1b2a1e)
        rect(0, 0, COLS * SIZE, TOP, 0x14201a)
        text(12, 8, "Score ${self.score}", 0xffffff)
        let best = "Best ${max(self.best, self.score)}"
        text(COLS * SIZE - text_width(best) - 12, 8, best, 0x9fc5a3)
        for y in 0..ROWS {
            for x in 0..COLS {
                if (x + y) % 2 == 0 { rect(x * SIZE, TOP + y * SIZE, SIZE, SIZE, 0x213325) }
            }
        }
        let a = self.apple
        circle(a.x * SIZE + SIZE / 2, TOP + a.y * SIZE + SIZE / 2, SIZE / 2 - 2, 0xff5e57)
        for i, c in self.worm {
            let shade = if i == 0 { 0x55efc4 } else if i % 2 == 0 { 0x00b894 } else { 0x00a383 }
            rect(c.x * SIZE + 1, TOP + c.y * SIZE + 1, SIZE - 2, SIZE - 2, shade)
        }
        match self.state {
            Paused => big_text(COLS * SIZE / 2 - 70, TOP + 130, "Paused", 0xffffff),
            Over => {
                big_text(COLS * SIZE / 2 - 100, TOP + 120, "Game over", 0xffffff)
                text(COLS * SIZE / 2 - 90, TOP + 170, "Space to play again", 0xb8d8bc)
            },
            _ => {},
        }
        show()
    }
}

fn main() {
    window(COLS * SIZE, ROWS * SIZE + TOP, "Worm")
    let g = Game {}
    g.reset()
    var last = now_ms()
    while true {
        var k = key()
        while k != "" {
            if k == " " {
                g.state = match g.state {
                    Playing => State.Paused,
                    Paused => State.Playing,
                    Over => {
                        g.reset()
                        State.Playing
                    },
                }
            } else {
                g.steer(k)
            }
            k = key()
        }
        if g.state == State.Playing && now_ms() - last >= g.speed {
            last = now_ms()
            g.step()
        }
        g.draw()
    }
}
