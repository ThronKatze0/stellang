// {{name}}: modeling a domain with structs and enums, and matching on them.

enum Suit { Hearts, Diamonds, Clubs, Spades }

enum Rank {
    Number(int),
    Jack,
    Queen,
    King,
    Ace,
}

struct Card {
    rank: Rank,
    suit: Suit,

    fn value(self) -> int {
        return match self.rank {
            .Number(n) => n,
            .Jack | .Queen | .King => 10,
            .Ace => 11,
        }
    }

    fn label(self) -> str {
        let r = match self.rank {
            .Number(n) => str(n),
            .Jack => "J",
            .Queen => "Q",
            .King => "K",
            .Ace => "A",
        }
        let s = match self.suit {
            .Hearts => "♥",
            .Diamonds => "♦",
            .Clubs => "♣",
            .Spades => "♠",
        }
        return "${r}${s}"
    }
}

enum Outcome {
    Win { by: int },
    Bust(int),
    Push,
}

fn score(hand: [Card]) -> int {
    return hand.map(c => c.value()).sum()
}

fn play(hand: [Card], dealer: int) -> Outcome {
    let me = score(hand)
    if me > 21 { return .Bust(me) }
    if me == dealer { return .Push }
    return .Win { by: me - dealer }
}

fn main() {
    let hand = [Card { rank: .Ace, suit: .Spades }, Card { rank: .Number(9), suit: .Hearts }]
    println("hand: ${hand.map(c => c.label()).join(" ")} = ${score(hand)}")
    match play(hand, 18) {
        .Win { by } => println("you win by ${by}"),
        .Bust(n) => println("bust with ${n}"),
        .Push => println("a push"),
    }
}
