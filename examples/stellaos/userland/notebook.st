// Files from a program: keep a list of notes in notes.txt in your home folder.

fn main() {
    let file = "notes.txt"
    var notes = read_file(file).lines()
    println("You have ${notes.len()} notes. Type one to add it, or an empty line to stop.")
    for i, n in notes { println("  ${i + 1}. ${n}") }
    while true {
        let t = input("> ")
        if t == "" { break }
        notes.push(t)
    }
    if write_file(file, notes.join("\n") + "\n") {
        println("Saved ${notes.len()} notes to ${file}.")
    } else {
        println("Couldn't save ${file}.")
    }
}
