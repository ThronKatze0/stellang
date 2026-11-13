// {{name}}: a stellang program. Run it with ▶ above `fn main`, or Ctrl+F5.

struct Star {
    name: str,
    magnitude: float,
    constellation: str?,
}

fn brightest(stars: [Star]) -> Star? {
    var best: Star? = none
    for s in stars {
        if let some(b) = best {
            if s.magnitude < b.magnitude { best = s }
        } else {
            best = s
        }
    }
    return best
}

fn main() {
    let stars = [
        Star { name: "Sirius", magnitude: -1.46, constellation: "Canis Major" },
        Star { name: "Vega", magnitude: 0.03, constellation: "Lyra" },
        Star { name: "Polaris", magnitude: 1.98 },
    ]
    for s in stars {
        println("⭐ ${s.name}: ${s.magnitude} (${s.constellation ?? "no constellation"})")
    }
    if let some(b) = brightest(stars) {
        println("the brightest is ${b.name}")
    }
}
