// Helpers for games: which keys are held, random numbers, and a fixed-rate clock.
//
// A game is a window program (wm.App) that returns true from `tick` to be drawn every frame:
//
//     let keys = game.Keys {}
//     wm.App {
//         tick: t => { update(t.dt); return true },
//         paint: s => draw(s),
//         key: e => keys.handle(e),
//     }

import kernel
import input

struct Keys {
    held: {str: bool} = {},
    hits: [str] = [],         // keys pressed since the last `take`

    fn handle(self, e: input.Event) {
        let k = name(e.key)
        if e.down && !e.repeat && !(self.held.get(k) ?? false) { self.hits.push(k) }
        self.held[k] = e.down
    }

    fn down(self, k: str) -> bool {
        return self.held.get(k) ?? false
    }

    // the keys pressed since last time (each press once)
    fn take(self) -> [str] {
        let h = self.hits
        self.hits = []
        return h
    }
}

// letters by their lower case, so Shift doesn't matter
fn name(k: str) -> str {
    return if k.len() == 1 { k.lower() } else { k }
}

// Random numbers (xorshift), seeded from the clock unless you give a seed.
struct Rng {
    state: int = 0x2545_f491_4f6c_dd1d,

    fn next(self) -> int {
        var x = self.state
        x = x ^ (x << 13)
        x = x ^ (x >> 7)
        x = x ^ (x << 17)
        self.state = x
        return x & 0x7fff_ffff_ffff_ffff
    }

    // 0 <= n < below
    fn below(self, below: int) -> int {
        return self.next() % max(below, 1)
    }

    fn chance(self, percent: int) -> bool {
        return self.below(100) < percent
    }
}

fn rng() -> Rng {
    let r = Rng { state: kernel.time_ms() * 6364136223846793005 + kernel.uptime() + 1442695040888963407 }
    if r.state == 0 { r.state = 1 }
    r.next()
    return r
}

// Fixed-rate updates whatever the frame rate: `steps(dt)` says how many `every`-ms steps are due.
struct Clock {
    every: int,
    acc: int = 0,

    fn steps(self, dt: int) -> int {
        self.acc += min(dt, 250)
        let n = self.acc / self.every
        self.acc -= n * self.every
        return n
    }
}
