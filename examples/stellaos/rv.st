// rv: RISC-V (RV64IM) machine code, for the compiler that runs inside StellaOS (cc.st).
//
// Asm collects 32-bit instruction words; jumps to labels and calls to functions not yet placed
// are fixed up once everything is laid out (link). Registers by number: zero 0, ra 1, sp 2,
// t0-t2 5-7, s0 8, s1 9, a0-a7 10-17, t3-t6 28-31.

const ZERO = 0
const RA = 1
const SP = 2
const T0 = 5
const T1 = 6
const T2 = 7
const FP = 8
const S1 = 9
const A0 = 10
const A1 = 11
const A2 = 12
const A3 = 13
const A4 = 14
const A5 = 15
const A7 = 17

fn r(op: int, rd: int, f3: int, rs1: int, rs2: int, f7: int) -> int {
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
}
fn i(op: int, rd: int, f3: int, rs1: int, imm: int) -> int {
    return (imm & 0xfff) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
}
fn s(f3: int, rs1: int, rs2: int, imm: int) -> int {
    return (imm >> 5 & 0x7f) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 0x1f) << 7 | 0x23
}
fn b(f3: int, rs1: int, rs2: int, imm: int) -> int {
    return (imm >> 12 & 1) << 31 | (imm >> 5 & 0x3f) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm >> 1 & 0xf) << 8 | (imm >> 11 & 1) << 7 | 0x63
}
fn u(op: int, rd: int, imm20: int) -> int {
    return (imm20 & 0xfffff) << 12 | rd << 7 | op
}
fn j(rd: int, imm: int) -> int {
    return (imm >> 20 & 1) << 31 | (imm >> 1 & 0x3ff) << 21 | (imm >> 11 & 1) << 20 | (imm >> 12 & 0xff) << 12 | rd << 7 | 0x6f
}

fn fits12(v: int) -> bool { return v >= -2048 && v <= 2047 }

// a fix-up: the word at `at` needs the distance to a label (or a function, by name)
struct Fix {
    at: int,
    kind: int,           // 0: jal, 1: auipc+addi pair (pc-relative address), 2: branch
    label: int = -1,     // a code label
    name: str = "",      // or a function
    rd: int = 0,
    data: int = -1,      // or an offset in the read-only data after the code (kind 1)
    var_at: int = -1,    // or an offset in the writable data (kind 1)
}

struct Asm {
    code: [int] = [],
    labels: [int] = [],
    fixes: [Fix] = [],

    fn here(self) -> int { return self.code.len() * 4 }
    fn emit(self, w: int) { self.code.push(w & 0xffffffff) }

    fn label(self) -> int {
        self.labels.push(-1)
        return self.labels.len() - 1
    }
    fn place(self, l: int) { self.labels[l] = self.here() }

    // integer ops
    fn add(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 0, a, b2, 0)) }
    fn sub(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 0, a, b2, 0x20)) }
    fn mul(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 0, a, b2, 1)) }
    fn div(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 4, a, b2, 1)) }
    fn rem(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 6, a, b2, 1)) }
    fn and(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 7, a, b2, 0)) }
    fn or(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 6, a, b2, 0)) }
    fn xor(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 4, a, b2, 0)) }
    fn sll(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 1, a, b2, 0)) }
    fn sra(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 5, a, b2, 0x20)) }
    fn slt(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 2, a, b2, 0)) }
    fn sltu(self, rd: int, a: int, b2: int) { self.emit(r(0x33, rd, 3, a, b2, 0)) }
    fn addi(self, rd: int, a: int, imm: int) { self.emit(i(0x13, rd, 0, a, imm)) }
    fn xori(self, rd: int, a: int, imm: int) { self.emit(i(0x13, rd, 4, a, imm)) }
    fn andi(self, rd: int, a: int, imm: int) { self.emit(i(0x13, rd, 7, a, imm)) }
    fn slli(self, rd: int, a: int, sh: int) { self.emit(i(0x13, rd, 1, a, sh & 63)) }
    fn srli(self, rd: int, a: int, sh: int) { self.emit(i(0x13, rd, 5, a, sh & 63)) }
    fn sltiu(self, rd: int, a: int, imm: int) { self.emit(i(0x13, rd, 3, a, imm)) }
    fn addiw(self, rd: int, a: int, imm: int) { self.emit(i(0x1b, rd, 0, a, imm)) }
    fn mv(self, rd: int, a: int) { self.addi(rd, a, 0) }
    fn seqz(self, rd: int, a: int) { self.sltiu(rd, a, 1) }
    fn snez(self, rd: int, a: int) { self.sltu(rd, ZERO, a) }
    fn neg(self, rd: int, a: int) { self.sub(rd, ZERO, a) }

    // memory
    fn ld(self, rd: int, base: int, off: int) { self.emit(i(0x03, rd, 3, base, off)) }
    fn lbu(self, rd: int, base: int, off: int) { self.emit(i(0x03, rd, 4, base, off)) }
    fn sd(self, rs: int, base: int, off: int) { self.emit(s(3, base, rs, off)) }
    fn sb(self, rs: int, base: int, off: int) { self.emit(s(0, base, rs, off)) }

    fn push(self, rs: int) {
        self.addi(SP, SP, -8)
        self.sd(rs, SP, 0)
    }
    fn pop(self, rd: int) {
        self.ld(rd, SP, 0)
        self.addi(SP, SP, 8)
    }

    // any 64-bit constant
    fn li(self, rd: int, v: int) {
        if fits12(v) {
            self.addi(rd, ZERO, v)
            return
        }
        if v >= -2147483648 && v <= 2147483647 {
            let hi = (v + 0x800) >> 12
            let lo = v - (hi << 12)
            self.emit(u(0x37, rd, hi))
            if lo != 0 { self.addiw(rd, rd, lo) }
            return
        }
        var lo = v & 0xfff
        if lo >= 0x800 { lo -= 0x1000 }
        self.li(rd, (v - lo) >> 12)
        self.slli(rd, rd, 12)
        if lo != 0 { self.addi(rd, rd, lo) }
    }

    // control flow: jumps reach anywhere in the program (a branch over a jal, never a bare branch)
    fn jump(self, l: int) {
        self.fixes.push(Fix { at: self.here(), kind: 0, label: l })
        self.emit(0)
    }
    fn jump_if_zero(self, rs: int, l: int) {
        self.emit(b(1, rs, ZERO, 8)) // bne rs, zero, +8
        self.jump(l)
    }
    fn jump_if_not_zero(self, rs: int, l: int) {
        self.emit(b(0, rs, ZERO, 8)) // beq rs, zero, +8
        self.jump(l)
    }
    fn call(self, name: str) {
        self.fixes.push(Fix { at: self.here(), kind: 0, name, rd: RA })
        self.emit(0)
    }
    fn ret(self) { self.emit(i(0x67, ZERO, 0, RA, 0)) }
    fn ecall(self) { self.emit(0x73) }

    // the address of something in the image (pc-relative, so the code runs wherever it is loaded)
    fn addr_data(self, rd: int, off: int) {
        self.fixes.push(Fix { at: self.here(), kind: 1, data: off, rd })
        self.emit(0)
        self.emit(0)
    }
    fn addr_var(self, rd: int, off: int) {
        self.fixes.push(Fix { at: self.here(), kind: 1, var_at: off, rd })
        self.emit(0)
        self.emit(0)
    }
}

struct Image {
    bytes: [int] = [],   // code, then read-only data
    data_at: int = 0,    // where the writable data starts (a page boundary after the bytes)
    data_size: int = 0,
}

// Lay out the code, the read-only data after it and the writable data on the next page, and
// resolve the fix-ups. `funcs` maps names to code offsets. Returns an error text, or "".
fn link(a: Asm, funcs: {str: int}, rodata: [int], data_size: int, img: Image) -> str {
    let code_size = a.code.len() * 4
    let ro_at = code_size
    let data_at = (code_size + rodata.len() + 4095) / 4096 * 4096
    for f in a.fixes {
        var target = 0
        if f.label >= 0 {
            target = a.labels[f.label]
        } else if f.name != "" {
            if !funcs.contains(f.name) { return "no function called ${f.name}" }
            target = funcs[f.name]
        } else if f.data >= 0 {
            target = ro_at + f.data
        } else {
            target = data_at + f.var_at
        }
        let d = target - f.at
        let w = f.at / 4
        if f.kind == 0 {
            if d < -(1 << 20) || d >= 1 << 20 { return "the program is too big (a jump is out of reach)" }
            a.code[w] = j(f.rd, d) & 0xffffffff
        } else {
            let hi = (d + 0x800) >> 12
            let lo = d - (hi << 12)
            a.code[w] = u(0x17, f.rd, hi) & 0xffffffff
            a.code[w + 1] = i(0x13, f.rd, 0, f.rd, lo) & 0xffffffff
        }
    }
    var bytes: [int] = []
    for w in a.code {
        bytes.push(w & 255)
        bytes.push(w >> 8 & 255)
        bytes.push(w >> 16 & 255)
        bytes.push(w >> 24 & 255)
    }
    for x in rodata { bytes.push(x) }
    img.bytes = bytes
    img.data_at = data_at
    img.data_size = data_size
    return ""
}
