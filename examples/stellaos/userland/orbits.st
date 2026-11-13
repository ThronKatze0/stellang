// Planets going round a sun: floats, sin() and cos(). Up/Down change the speed.

struct Planet {
    r: float,          // distance from the sun
    speed: float,      // radians per frame
    size: int,
    color: int,
    angle: float = 0.0,
}

fn main() {
    let w = 520
    let h = 420
    window(w, h, "Orbits")
    let cx = float(w / 2)
    let cy = float(h / 2)
    let planets = [
        Planet { r: 50.0, speed: 0.047, size: 5, color: 0xb2bec3 },
        Planet { r: 80.0, speed: 0.035, size: 8, color: 0xfdcb6e },
        Planet { r: 115.0, speed: 0.029, size: 9, color: 0x0984e3 },
        Planet { r: 150.0, speed: 0.024, size: 7, color: 0xe17055 },
        Planet { r: 190.0, speed: 0.013, size: 16, color: 0xe1b382 },
    ]
    var stars: [int] = []
    for i in 0..80 { stars.push(random(w * h)) }
    var warp = 1.0
    var t = 0
    while true {
        let k = key()
        if k == "ArrowUp" { warp = warp * 1.5 }
        if k == "ArrowDown" { warp = warp / 1.5 }
        clear(0x0c0b1d)
        for s in stars { rect(s % w, s / w, 1, 1, 0x8e8aa8) }
        // the sun, glowing
        circle(int(cx), int(cy), 26, 0xff9f1a)
        circle(int(cx), int(cy), 20, 0xffd32a)
        for p in planets {
            p.angle += p.speed * warp
            let x = cx + p.r * cos(p.angle)
            let y = cy + p.r * sin(p.angle) * 0.85
            circle(int(x), int(y), p.size, p.color)
        }
        text(10, 8, "speed x${(warp * 100.0).round() / 100.0} (up/down)", 0xd2dae2)
        show()
        t += 1
    }
}
