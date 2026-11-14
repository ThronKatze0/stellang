// A little tune through the sound card: beep(hz, ms) plays a tone,
// note("A4") gives a note's frequency.

fn play(tune: str, ms: int) {
    for n in tune.split(" ") {
        let hz = note(n)
        if hz > 0 { beep(hz, ms - 20) }
        print("${n} ")
        sleep(ms)
    }
    println("")
}

fn main() {
    println("♪ Ode to Joy")
    play("E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4 D4 D4", 300)
    play("E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4 C4 C4", 300)
}
