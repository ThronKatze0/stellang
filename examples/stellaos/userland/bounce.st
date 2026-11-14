// Balls bouncing around a window. Click to add one, arrow keys push them all,
// Space clears. Graphics: window(), clear(), circle(), text(), show().

struct Ball {
    x: int,
    y: int,
    dx: int,
    dy: int,
    r: int,
    color: int,
}

const W = 480
const H = 360

fn ball(x: int, y: int) -> Ball {
    let colors = [0xff6b6b, 0xfeca57, 0x48dbfb, 0x1dd1a1, 0xff9ff3, 0x54a0ff]
    return Ball { x: x * 16, y: y * 16, dx: random(9) - 4 + 1, dy: random(9) - 4 - 1, r: 8 + random(14), color: colors[random(colors.len())] }
}

fn main() {
    window(W, H, "Bounce")
    var balls: [Ball] = []
    for i in 0..5 { balls.push(ball(W / 2, H / 2)) }
    var was_down = false
    var frames = 0
    while true {
        let k = key()
        if k == " " { balls.clear() }
        for b in balls {
            if k == "ArrowLeft" { b.dx -= 2 }
            if k == "ArrowRight" { b.dx += 2 }
            if k == "ArrowUp" { b.dy -= 2 }
            if k == "ArrowDown" { b.dy += 2 }
        }
        if mouse_down() && !was_down { balls.push(ball(mouse_x(), mouse_y())) }
        was_down = mouse_down()
        clear(0x1e272e)
        for b in balls {
            b.dy += 1
            b.x += b.dx * 4
            b.y += b.dy * 4
            if b.x < b.r * 16 { b.x = b.r * 16; b.dx = abs(b.dx) }
            if b.x > (W - b.r) * 16 { b.x = (W - b.r) * 16; b.dx = -abs(b.dx) }
            if b.y > (H - b.r) * 16 {
                b.y = (H - b.r) * 16
                b.dy = -abs(b.dy) + 1
            }
            circle(b.x / 16, b.y / 16, b.r, b.color)
        }
        text(10, 8, "${balls.len()} balls · click to add · Space clears", 0xd2dae2)
        show()
        frames += 1
    }
}
