// The primes below 100000 (a sieve), and how long that took.

fn main() {
    let n = 100000
    let start = now_ms()
    var sieve: [bool] = []
    for i in 0..n { sieve.push(true) }
    var primes: [int] = []
    for i in 2..n {
        if sieve[i] {
            primes.push(i)
            var j = i * i
            while j < n {
                sieve[j] = false
                j += i
            }
        }
    }
    println("${primes.len()} primes below ${n}, found in ${now_ms() - start} ms")
    println("the last ten: ${primes.slice(primes.len() - 10, primes.len())}")
}
