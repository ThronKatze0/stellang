// Guess the number: a game in the console.

fn main() {
    let secret = random(100) + 1
    println("I'm thinking of a number from 1 to 100.")
    var tries = 0
    while true {
        let answer = input("Your guess: ")
        if !is_number(answer) {
            println("That's not a number.")
            continue
        }
        let g = parse_int(answer)
        tries += 1
        if g < secret {
            println("Higher!")
        } else if g > secret {
            println("Lower!")
        } else {
            println("Yes! ${secret}, in ${tries} tries.")
            break
        }
    }
}
