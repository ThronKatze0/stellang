// Your first program. Press Run (or F5): it is compiled to RISC-V machine code
// right here and runs as a process of its own.

fn main() {
    println("Hello from a compiled program!")
    let name = input("What's your name? ")
    println("Nice to meet you, ${name}.")
    for i in 1..6 {
        println("${i} squared is ${i * i}")
    }
}
