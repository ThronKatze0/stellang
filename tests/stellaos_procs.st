// StellaOS processes and the compiler inside it (tests/e2e.rs boots this in QEMU):
// hand-made machine code that attacks the kernel (each attempt must end only that program), an
// endless loop that must not freeze the kernel, then programs compiled by cc.st: the language,
// runtime errors with their lines, compile errors with their positions, input, memory limits.

import kernel
import rv
import proc
import cc

extern fn st_k_byte(s: str, i: int) -> int

fn build(f: fn(rv.Asm)) -> rv.Image {
    let a = rv.Asm {}
    f(a)
    let img = rv.Image {}
    var ro: [int] = []
    let msg = "hi from user mode\n"
    for i in 0..msg.len() { ro.push(st_k_byte(msg, i)) }
    let e = rv.link(a, {"x": 0}, ro, 64, img)
    if e != "" { println("link: ${e}") }
    return img
}

fn sys() -> proc.Sys {
    return proc.Sys {
        write: (p: proc.Proc, s: str) => print("[${p.name}] ${s}"),
        exited: (p: proc.Proc) => println("[${p.name}] ended: code ${p.code} ${p.why}"),
    }
}

fn start(ps: proc.Procs, name: str, img: rv.Image, wait: bool) -> proc.Proc {
    let p = ps.spawn(name, "ada", img.bytes, img.data_at, img.data_size, sys()) catch e {
        println("spawn: ${e}")
        kernel.shutdown(1)
        panic("unreachable")
    }
    if wait {
        let t = kernel.uptime()
        while !p.done() && kernel.uptime() - t < 3000 { kernel.idle() }
    }
    return p
}

const PROGS = [
    ["a_features.st", "const GREETING = \"hi\"\nvar counter = 0\nlet primes: [int] = [2, 3, 5]\n\nstruct Item {\n    name: str,\n    count: int = 1,\n    tags: [str] = [],\n}\n\nstruct Bag {\n    items: [Item] = [],\n    fn add(self, name: str) {\n        for it in self.items {\n            if it.name == name {\n                it.count += 1\n                return\n            }\n        }\n        self.items.push(Item { name })\n    }\n    fn total(self) -> int {\n        var t = 0\n        for it in self.items { t += it.count }\n        return t\n    }\n}\n\nfn bump() -> int {\n    counter += 1\n    return counter\n}\n\nfn main() {\n    let b = Bag {}\n    for w in \"a b a c a b\".split(\" \") { b.add(w) }\n    for i, it in b.items { println(\"\${i}: \${it.name} x\${it.count}\") }\n    println(\"total \${b.total()}\")\n    bump()\n    bump()\n    println(\"\${GREETING} counter=\${counter} primes=\${primes}\")\n    primes[1] = 7\n    primes[2] *= 10\n    println(primes)\n    var k = 0\n    while true {\n        k += 1\n        if k % 2 == 0 { continue }\n        if k > 7 { break }\n        print(\"\${k} \")\n    }\n    println(\"\")\n    println(\"abc\" < \"abd\")\n    println(\"x=\${-5 / 2} \${-5 % 2} \${7 & 3} \${1 << 10} \${-16 >> 2} \${~0}\")\n    let s = \"  Hello, World  \"\n    println(\"[\${s.trim()}] \${s.trim().lower()} \${s.find(\"World\")} \${s.replace(\"l\", \"L\")}\")\n    println(\"\${\"ab\".repeat(3)} \${\"héllo\".chars().len()} \${\"a,b,,c\".split(\",\")} \${\"line1\\nline2\\n\".lines()}\")\n    println(\"\${parse_int(\" -42 \")} \${is_number(\"12x\")} \${char(65)}\${char(233)} \${max(3, 9)} \${abs(-4)}\")\n    println(note(\"A4\"))\n    println(note(\"C4\"))\n    let nested: [[int]] = [[1, 2], [3]]\n    nested[0].push(9)\n    println(\"\${nested[0]} \${nested.len()}\")\n    var flags: [bool] = [true, false]\n    println(flags)\n    let big = 9223372036854775807\n    println(big + 1)\n    println(pid() > 0)\n    println(\"é\".len())\n    var str_acc = \"\"\n    for c in \"abc\" { str_acc = c + str_acc }\n    println(str_acc)\n}\n"],
    ["b_divzero.st", "fn main() {\n    let a = 10\n    var b = 0\n    println(\"before\")\n    println(a / b)\n}\n"],
    ["c_stack.st", "fn deep(n: int) -> int { return deep(n + 1) + 1 }\nfn main() { println(deep(0)) }\n"],
    ["d_err1.st", "fn main() {\n    let x = 5\n    x = 6\n}\n"],
    ["e_err2.st", "fn main() {\n    let s: str = 5\n}\n"],
    ["f_err3.st", "fn main() {\n    println(undefined_thing)\n}\n"],
    ["g_err4.st", "fn main() {\n    let x = \"unterminated\n}\n"],
    ["h_err5.st", "struct P { x: int }\nfn main() {\n    let p = P { x: 1 }\n    p.y = 2\n    __syscall(1, 2)\n}\n"],
    ["i_err6.st", "fn add(a: int, b: int) -> int { return a + b }\nfn main() {\n    println(add(1))\n}\n"],
    ["j_spin.st", "fn main() {\n    var i = 0\n    while true { i += 1 }\n}\n"],
    ["k_mem.st", "fn main() {\n    var s = \"x\"\n    while true { s = s + s }\n}\n"],
    ["l_input.st", "fn main() {\n    let name = input(\"name? \")\n    println(\"hello \${name}!\")\n    let n = parse_int(read_line())\n    println(\"double: \${n * 2}\")\n}\n"]
]

fn main() {
    let ps = proc.Procs {}
    println("== machine code")
    start(ps, "hello", build((a: rv.Asm) => {
        a.addr_data(rv.A0, 0)
        a.li(rv.A1, 18)
        a.li(rv.A7, 1)
        a.ecall()
        a.li(rv.A0, 7)
        a.li(rv.A7, 0)
        a.ecall()
    }), true)
    start(ps, "null", build((a: rv.Asm) => { a.ld(rv.A0, rv.ZERO, 0) }), true)
    start(ps, "kernel-write", build((a: rv.Asm) => {
        a.li(rv.T0, 0x80200000)
        a.sd(rv.ZERO, rv.T0, 0)
    }), true)
    start(ps, "device-write", build((a: rv.Asm) => {
        a.li(rv.T0, 0x10000000)          // the UART
        a.sd(rv.ZERO, rv.T0, 0)
    }), true)
    start(ps, "code-write", build((a: rv.Asm) => {
        a.emit(rv.u(0x17, rv.T0, 0))     // auipc t0, 0: its own code
        a.sd(rv.ZERO, rv.T0, 0)
    }), true)
    start(ps, "bad-pointer", build((a: rv.Asm) => {
        a.li(rv.A0, 0x80200000)          // write(kernel memory, 16)
        a.li(rv.A1, 16)
        a.li(rv.A7, 1)
        a.ecall()
    }), true)
    start(ps, "recurse", build((a: rv.Asm) => {
        let l = a.label()
        a.place(l)
        a.push(rv.RA)
        a.jump(l)
    }), true)
    start(ps, "wfi", build((a: rv.Asm) => { a.emit(0x10500073) }), true)
    start(ps, "csr", build((a: rv.Asm) => { a.emit(0x18002573) }), true)   // csrr a0, satp
    start(ps, "bad-syscall", build((a: rv.Asm) => {
        a.li(rv.A7, 999)
        a.ecall()
    }), true)
    let spin = start(ps, "spin", build((a: rv.Asm) => {
        let l = a.label()
        a.place(l)
        a.addi(rv.T0, rv.T0, 1)
        a.jump(l)
    }), false)
    let t0 = kernel.uptime()
    var turns = 0
    while kernel.uptime() - t0 < 500 {
        kernel.idle()
        turns += 1
    }
    println("kernel turns while spinning: ${turns}; spin cpu ${spin.cpu} ms, ${spin.state}")
    spin.kill("killed")
    println("== compiled")
    for pr in PROGS {
        println("=== ${pr[0]}")
        let out = cc.compile(pr[1], () => kernel.uptime())
        if !out.errors.is_empty() {
            for e in out.errors { println("compile error ${e.line}:${e.col}: ${e.msg}") }
            continue
        }
        let p = ps.spawn(pr[0], "ada", out.image.bytes, out.image.data_at, out.image.data_size, proc.Sys {
            write: (p: proc.Proc, s: str) => print(s),
            exited: (p: proc.Proc) => println("[exit ${p.code}] ${p.why}"),
        }) catch e {
            println("spawn: ${e}")
            continue
        }
        let t = kernel.uptime()
        var fed = 0
        while !p.done() && kernel.uptime() - t < 3000 {
            kernel.idle()
            if p.state == "input" {
                p.give_line(if fed == 0 { "Ada" } else { "21" })
                fed += 1
            }
        }
        if !p.done() {
            println("[still running after 3 s: killing]")
            p.kill("killed")
        }
    }
    // a program saved as a file and loaded back
    let out = cc.compile("fn main() { println(\"from a file\") }", () => kernel.uptime())
    let text = cc.exe_text(out.image)
    if let img = cc.exe_parse(text) {
        let p = start(ps, "exe", img, true)
    }
    println("exe parse of junk: ${cc.exe_parse("#!stella-exe 1 4096 16\nzz") == none}")
    println("done")
    kernel.shutdown(0)
}
