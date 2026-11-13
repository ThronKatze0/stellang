// Mines: clear the field without stepping on a mine. Click to uncover, right-click to flag.
// A game made of buttons: a web-style app (JSX + signals), like the Calculator.

import web
import ui
import wm
import game

const SIZE = 9
const MINES = 10

const CSS = """
    .mines { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 12px; background: #eef1f6; height: 100% }
    .top { display: flex; gap: 10px; align-items: center; width: 100% }
    .count { flex: 1; font-weight: bold; font-size: 15px }
    .grid { display: grid; grid-template-columns: repeat(9, 1fr); gap: 3px; width: 288px }
    .cell { height: 29px; padding: 0; border: none; border-radius: 5px; background: #b9c4d6; font-weight: bold }
    .open { background: #fbfcfe; color: #2d3436 }
    .boom { background: #ff6b6b; color: white }
    .flag { background: #ffd56b; color: #b33939 }
    .n1 { color: #1e6fd9 }
    .n2 { color: #1e9e54 }
    .n3 { color: #d63031 }
    .n4 { color: #6c3ad1 }
    .msg { font-weight: bold; color: #6c5ce7 }
"""

struct Board {
    mine: [bool] = [],
    open: [bool] = [],
    flag: [bool] = [],
    state: str = "new",       // new, playing, lost, won

    fn reset(self) {
        self.mine = []
        self.open = []
        self.flag = []
        for i in 0..SIZE * SIZE {
            self.mine.push(false)
            self.open.push(false)
            self.flag.push(false)
        }
        self.state = "new"
    }

    // mines go down on the first click, never under it
    fn plant(self, safe: int) {
        let rng = game.rng()
        var n = 0
        while n < MINES {
            let i = rng.below(SIZE * SIZE)
            if !self.mine[i] && max(abs(i % SIZE - safe % SIZE), abs(i / SIZE - safe / SIZE)) > 1 {
                self.mine[i] = true
                n += 1
            }
        }
        self.state = "playing"
    }

    fn around(self, i: int) -> [int] {
        var out: [int] = []
        let x = i % SIZE
        let y = i / SIZE
        for dy in [-1, 0, 1] {
            for dx in [-1, 0, 1] {
                let nx = x + dx
                let ny = y + dy
                if (dx != 0 || dy != 0) && nx >= 0 && ny >= 0 && nx < SIZE && ny < SIZE { out.push(ny * SIZE + nx) }
            }
        }
        return out
    }

    fn count(self, i: int) -> int {
        return self.around(i).filter(j => self.mine[j]).len()
    }

    fn uncover(self, i: int) {
        if self.state == "new" { self.plant(i) }
        if self.state != "playing" || self.flag[i] || self.open[i] { return }
        if self.mine[i] {
            self.state = "lost"
            for j in 0..SIZE * SIZE {
                if self.mine[j] { self.open[j] = true }
            }
            return
        }
        // flood the empty area
        var todo = [i]
        while !todo.is_empty() {
            let j = todo.pop()
            if self.open[j] { continue }
            self.open[j] = true
            if self.count(j) == 0 {
                for k in self.around(j) {
                    if !self.open[k] && !self.mine[k] { todo.push(k) }
                }
            }
        }
        var closed = 0
        for j in 0..SIZE * SIZE {
            if !self.open[j] { closed += 1 }
        }
        if closed == MINES { self.state = "won" }
    }
}

fn Mines(b: Board) -> Node {
    let version = signal(0)            // bumped after each move: render again
    let changed = () => version.set(version.get() + 1)
    let flags = b.flag.filter(f => f).len()
    return <div class="mines">
        <div class="top">
            <span class="count">"✹ ${MINES - flags} left"</span>
            <button onclick={() => {
                b.reset()
                changed()
            }}>"New game"</button>
        </div>
        <div class="grid">
            for i in 0..SIZE * SIZE {
                <button class={cell_class(b, i)}
                    onclick={() => {
                        b.uncover(i)
                        changed()
                    }}
                    oncontextmenu={() => {
                        if !b.open[i] && b.state != "lost" && b.state != "won" { b.flag[i] = !b.flag[i] }
                        changed()
                    }}>{cell_text(b, i)}</button>
            }
        </div>
        <div class="msg">{if b.state == "won" { "You cleared the field! ★" } else if b.state == "lost" { "Boom. Try again?" } else { "" }}</div>
    </div>
}

fn cell_class(b: Board, i: int) -> str {
    if !b.open[i] { return if b.flag[i] { "cell flag" } else { "cell" } }
    if b.mine[i] { return "cell boom" }
    return "cell open n${b.count(i)}"
}

fn cell_text(b: Board, i: int) -> str {
    if !b.open[i] { return if b.flag[i] { "⚑" } else { "" } }
    if b.mine[i] { return "✹" }
    let n = b.count(i)
    return if n == 0 { "" } else { str(n) }
}

fn open(d: wm.Desktop) {
    let b = Board {}
    b.reset()
    let w = d.open("Mines", "✹", 0x636e72, 312, 400, ui.styled(() => <Mines b={b} />, CSS))
    w.resizable = false
}
