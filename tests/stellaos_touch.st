// StellaOS's touchpad driver without a touchpad (tests/e2e.rs boots this in QEMU): ACPI tables of two
// made-up laptops (one with the touchpad's I²C address in the table, one, Intel reference style,
// filling it in at run time) and report descriptors of a precision touchpad, with and without the
// mouse collection touchpads start in. The bytes were made by an encoder that writes them the way
// firmware compilers and touchpad vendors do (see the commit that added this file).

import kernel
import acpi
import hid

const DSDT_A = [16, 72, 9, 92, 46, 95, 83, 66, 95, 80, 67, 48, 48, 91, 130, 73, 7, 73, 50, 67, 49, 8, 95, 65, 68, 82, 12, 1, 0, 21, 0, 91, 130, 71, 6, 84, 80, 68, 48, 8, 95, 72, 73, 68, 13, 69, 76, 65, 78, 48, 68, 54, 49, 0, 8, 95, 67, 73, 68, 12, 65, 208, 12, 80, 20, 15, 95, 68, 83, 77, 4, 160, 5, 1, 164, 10, 1, 164, 10, 32, 8, 83, 66, 70, 66, 17, 38, 10, 35, 142, 30, 0, 2, 0, 1, 2, 0, 0, 1, 6, 0, 128, 26, 6, 0, 21, 0, 92, 95, 83, 66, 46, 80, 67, 48, 48, 46, 73, 50, 67, 49, 0, 121, 0, 20, 11, 95, 67, 82, 83, 0, 164, 83, 66, 70, 66, 91, 130, 15, 73, 50, 67, 48, 8, 95, 65, 68, 82, 12, 0, 0, 21, 0]
const DSDT_B = [16, 78, 4, 92, 47, 3, 95, 83, 66, 95, 80, 67, 48, 48, 73, 50, 67, 48, 91, 130, 59, 84, 80, 68, 49, 8, 95, 72, 73, 68, 12, 65, 208, 12, 80, 8, 83, 66, 70, 66, 17, 38, 10, 35, 142, 30, 0, 2, 0, 1, 2, 0, 0, 1, 6, 0, 64, 66, 15, 0, 0, 0, 92, 95, 83, 66, 46, 80, 67, 48, 48, 46, 73, 50, 67, 48, 0, 121, 0]
const SSDT_B = [16, 31, 92, 46, 95, 83, 66, 95, 80, 67, 48, 48, 91, 130, 18, 73, 50, 67, 48, 20, 12, 95, 65, 68, 82, 0, 164, 12, 0, 0, 21, 0]
const PTP_WITH_MOUSE = [5, 13, 9, 5, 161, 1, 133, 1, 5, 13, 9, 34, 161, 2, 21, 0, 37, 1, 117, 1, 149, 1, 9, 66, 129, 2, 9, 71, 129, 2, 149, 6, 129, 1, 117, 8, 149, 1, 37, 15, 9, 81, 129, 2, 5, 1, 21, 0, 38, 128, 12, 117, 16, 149, 1, 9, 48, 129, 2, 38, 208, 7, 9, 49, 129, 2, 192, 5, 13, 9, 34, 161, 2, 21, 0, 37, 1, 117, 1, 149, 1, 9, 66, 129, 2, 9, 71, 129, 2, 149, 6, 129, 1, 117, 8, 149, 1, 37, 15, 9, 81, 129, 2, 5, 1, 21, 0, 38, 128, 12, 117, 16, 149, 1, 9, 48, 129, 2, 38, 208, 7, 9, 49, 129, 2, 192, 5, 13, 9, 84, 21, 0, 37, 5, 117, 8, 149, 1, 129, 2, 5, 9, 9, 1, 37, 1, 117, 1, 149, 1, 129, 2, 117, 7, 129, 1, 192, 5, 1, 9, 2, 161, 1, 9, 1, 161, 0, 133, 2, 5, 9, 25, 1, 41, 2, 21, 0, 37, 1, 117, 1, 149, 2, 129, 2, 149, 6, 129, 1, 5, 1, 9, 48, 9, 49, 21, 129, 37, 127, 117, 8, 149, 2, 129, 6, 192, 192, 5, 13, 9, 14, 161, 1, 133, 3, 9, 82, 37, 10, 117, 8, 149, 1, 177, 2, 192]
const PTP_ONLY = [5, 13, 9, 5, 161, 1, 133, 1, 5, 13, 9, 34, 161, 2, 21, 0, 37, 1, 117, 1, 149, 1, 9, 66, 129, 2, 9, 71, 129, 2, 149, 6, 129, 1, 117, 8, 149, 1, 37, 15, 9, 81, 129, 2, 5, 1, 21, 0, 38, 128, 12, 117, 16, 149, 1, 9, 48, 129, 2, 38, 208, 7, 9, 49, 129, 2, 192, 5, 13, 9, 34, 161, 2, 21, 0, 37, 1, 117, 1, 149, 1, 9, 66, 129, 2, 9, 71, 129, 2, 149, 6, 129, 1, 117, 8, 149, 1, 37, 15, 9, 81, 129, 2, 5, 1, 21, 0, 38, 128, 12, 117, 16, 149, 1, 9, 48, 129, 2, 38, 208, 7, 9, 49, 129, 2, 192, 5, 13, 9, 84, 21, 0, 37, 5, 117, 8, 149, 1, 129, 2, 5, 9, 9, 1, 37, 1, 117, 1, 149, 1, 129, 2, 117, 7, 129, 1, 192, 5, 13, 9, 14, 161, 1, 133, 3, 9, 82, 37, 10, 117, 8, 149, 1, 177, 2, 192]

fn show(ds: [acpi.HidI2c]) {
    for d in ds {
        println("device ${d.name} hid ${d.hid} address 0x${hex(d.address)} speed ${d.speed} on ${d.controller} adr 0x${hex(d.adr)} registers ${d.registers}")
    }
}

fn hex(v: int) -> str {
    if v < 0 { return "-1" }
    let d = "0123456789abcdef"
    var s = ""
    var x = v
    if x == 0 { return "0" }
    while x > 0 {
        s = d[x & 15] + s
        x = x >> 4
    }
    return s
}

// a touchpad-mode report: two fingers (tip, x, y) and the button
fn ptp(f0: [int], f1: [int], button: int) -> [int] {
    var r = [1]
    var n = 0
    for f in [f0, f1] {
        let tip = if f.is_empty() { 0 } else { 1 }
        n += tip
        let x = if f.is_empty() { 0 } else { f[0] }
        let y = if f.is_empty() { 0 } else { f[1] }
        r.push(tip | 2)
        r.push(0)
        r.push(x & 255)
        r.push(x >> 8)
        r.push(y & 255)
        r.push(y >> 8)
    }
    r.push(n)
    r.push(button)
    return r
}

fn main() {
    println("== ACPI A")
    show(acpi.hid_i2c([DSDT_A]))
    println("== ACPI B")
    show(acpi.hid_i2c([DSDT_B, SSDT_B]))
    println("== nothing")
    show(acpi.hid_i2c([[1, 2, 3, 0x5b, 0x82]]))

    println("== mouse mode")
    let m = hid.pad(PTP_WITH_MOUSE)
    println("mode ${m.mode} ids ${m.ids} report ${m.mouse_report}")
    println(m.feed([2, 1, 5, 0xfb], 0))
    println(m.feed([2, 0, 200, 0], 10))
    println(m.feed([1, 3, 0, 0, 0, 0, 0], 20))      // a touchpad report: ignored in mouse mode

    println("== touchpad mode")
    let p = hid.pad(PTP_ONLY)
    println("mode ${p.mode} report ${p.pad_report} contacts ${p.contacts.len()} range ${p.range} buttons ${p.buttons.len()}")
    println(p.feed(ptp([1000, 1000], [], 0), 0))        // a finger down
    println(p.feed(ptp([1100, 1000], [], 0), 20))       // moves right: 100 of 3200 -> 50 pixels
    println(p.feed(ptp([1100, 1300], [], 0), 40))       // and down
    println(p.feed(ptp([], [], 0), 60))                  // lifted (it moved: no tap)
    println(p.feed(ptp([500, 500], [], 0), 1000))       // a tap
    println(p.feed(ptp([], [], 0), 1100))
    println(p.feed(ptp([500, 500], [900, 500], 0), 2000)) // two fingers: scroll
    println(p.feed(ptp([500, 700], [900, 700], 0), 2020))
    println(p.feed(ptp([], [], 0), 2500))
    println(p.feed(ptp([500, 500], [], 1), 3000))        // pressed (a physical click)
    println(p.feed(ptp([520, 500], [], 1), 3020))
    println(p.feed(ptp([], [], 0), 3400))                // released
    println("done")
    kernel.shutdown(0)
}
