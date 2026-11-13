// Draw with the mouse. Number keys pick a color, C clears.

fn main() {
    window(520, 380, "Sketch")
    let colors = [0xffffff, 0xff6b6b, 0xfeca57, 0x1dd1a1, 0x54a0ff, 0xff9ff3]
    var color = 0
    clear(0x2d3436)
    var lx = -1
    var ly = -1
    while true {
        let k = key()
        if k == "c" { clear(0x2d3436) }
        if k >= "1" && k <= "6" { color = parse_int(k) - 1 }
        if mouse_down() {
            let x = mouse_x()
            let y = mouse_y()
            if lx >= 0 { line(lx, ly, x, y, colors[color]) }
            circle(x, y, 2, colors[color])
            lx = x
            ly = y
        } else {
            lx = -1
        }
        rect(0, 0, 520, 24, 0x1e272e)
        for i in 0..colors.len() {
            rect(8 + i * 26, 4, 18, 16, colors[i])
            if i == color { rect(8 + i * 26, 21, 18, 2, 0xffffff) }
        }
        text(180, 4, "keys 1-6: colors · C: clear", 0xb2bec3)
        show()
    }
}
