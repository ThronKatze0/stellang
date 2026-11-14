// stellang on bare metal: RISC-V 64 on QEMU's `virt` machine (OpenSBI loads us at 0x80200000 in
// supervisor mode). Comes after runtime_kernel.c (what every machine shares).
//
//   boot      _start: zero .bss, set the stack, turn on the FPU, then kmain -> the program's main()
//   traps     timer ticks (SBI), the UART's "byte received" through the PLIC; exceptions panic
//   memory    RAM after the kernel, its size from the device tree
//   exit      main returning (or a panic) powers QEMU off through its test device, with the exit code

// ---- boot ----

__asm__(
    ".section .text.boot, \"ax\"\n"
    ".globl _start\n"
    "_start:\n"
    "  .option push\n"
    "  .option norelax\n"
    "  la t0, __bss_start\n" // a0 = hart id, a1 = device tree (from OpenSBI): keep them
    "  la t1, __bss_end\n"
    "1: bgeu t0, t1, 2f\n"
    "  sd zero, 0(t0)\n"
    "  addi t0, t0, 8\n"
    "  j 1b\n"
    "2: la sp, __stack_top\n"
    "  li t0, 0x6000\n" // sstatus.FS = dirty: floating point on
    "  csrs sstatus, t0\n"
    "  call kmain\n"
    "3: wfi\n"
    "  j 3b\n"
    "  .option pop\n"
    ".text\n");

// The trap vector: save the registers a C call may clobber (integer and float), call st_trap, restore.
__asm__(
    ".text\n"
    ".balign 4\n"
    ".globl trap_vector\n"
    "trap_vector:\n"
    "  csrrw sp, sscratch, sp\n" // sscratch is 0 in the kernel, a process's frame while it runs
    "  bnez sp, user_trap\n"
    "  csrrw sp, sscratch, sp\n"
    "  addi sp, sp, -320\n"
    "  sd ra, 0(sp)\n  sd t0, 8(sp)\n  sd t1, 16(sp)\n  sd t2, 24(sp)\n"
    "  sd a0, 32(sp)\n  sd a1, 40(sp)\n  sd a2, 48(sp)\n  sd a3, 56(sp)\n"
    "  sd a4, 64(sp)\n  sd a5, 72(sp)\n  sd a6, 80(sp)\n  sd a7, 88(sp)\n"
    "  sd t3, 96(sp)\n  sd t4, 104(sp)\n  sd t5, 112(sp)\n  sd t6, 120(sp)\n"
    "  fsd ft0, 128(sp)\n  fsd ft1, 136(sp)\n  fsd ft2, 144(sp)\n  fsd ft3, 152(sp)\n"
    "  fsd ft4, 160(sp)\n  fsd ft5, 168(sp)\n  fsd ft6, 176(sp)\n  fsd ft7, 184(sp)\n"
    "  fsd fa0, 192(sp)\n  fsd fa1, 200(sp)\n  fsd fa2, 208(sp)\n  fsd fa3, 216(sp)\n"
    "  fsd fa4, 224(sp)\n  fsd fa5, 232(sp)\n  fsd fa6, 240(sp)\n  fsd fa7, 248(sp)\n"
    "  fsd ft8, 256(sp)\n  fsd ft9, 264(sp)\n  fsd ft10, 272(sp)\n  fsd ft11, 280(sp)\n"
    "  frcsr t0\n  sd t0, 288(sp)\n"
    "  csrr a0, scause\n  csrr a1, sepc\n  csrr a2, stval\n  mv a3, sp\n"
    "  call st_trap\n"
    "  ld t0, 288(sp)\n  fscsr t0\n"
    "  fld ft0, 128(sp)\n  fld ft1, 136(sp)\n  fld ft2, 144(sp)\n  fld ft3, 152(sp)\n"
    "  fld ft4, 160(sp)\n  fld ft5, 168(sp)\n  fld ft6, 176(sp)\n  fld ft7, 184(sp)\n"
    "  fld fa0, 192(sp)\n  fld fa1, 200(sp)\n  fld fa2, 208(sp)\n  fld fa3, 216(sp)\n"
    "  fld fa4, 224(sp)\n  fld fa5, 232(sp)\n  fld fa6, 240(sp)\n  fld fa7, 248(sp)\n"
    "  fld ft8, 256(sp)\n  fld ft9, 264(sp)\n  fld ft10, 272(sp)\n  fld ft11, 280(sp)\n"
    "  ld ra, 0(sp)\n  ld t0, 8(sp)\n  ld t1, 16(sp)\n  ld t2, 24(sp)\n"
    "  ld a0, 32(sp)\n  ld a1, 40(sp)\n  ld a2, 48(sp)\n  ld a3, 56(sp)\n"
    "  ld a4, 64(sp)\n  ld a5, 72(sp)\n  ld a6, 80(sp)\n  ld a7, 88(sp)\n"
    "  ld t3, 96(sp)\n  ld t4, 104(sp)\n  ld t5, 112(sp)\n  ld t6, 120(sp)\n"
    "  addi sp, sp, 320\n"
    "  sret\n");

extern void trap_vector(void);

// ---- user mode: processes ----
//
// A process runs in user mode with its own page table. Its registers live in a frame (one page):
//   0 pc, 8*i x1..x31, 256+8*i f0..f31, 512 fcsr, 520 satp, 528 scause, 536 stval,
//   544.. the kernel's callee-saved registers while the process runs (ra sp s0-s11 fs0-fs11 fcsr)
// user_enter saves the kernel's registers in the frame, puts the process's in place and srets; the
// next trap (a system call, a fault, any interrupt) comes to user_trap, which saves the process's
// registers and returns from user_enter with scause. The kernel itself runs without paging, so it
// never sees user addresses: the stellang side checks them and translates them itself.
__asm__(
    ".text\n"
    ".balign 4\n"
    ".globl user_enter\n"
    "user_enter:\n"
    "  csrci sstatus, 2\n" // no interrupts until we are in user mode
"  sd ra, 544(a0)\n"
"  sd sp, 552(a0)\n"
"  sd s0, 560(a0)\n"
"  sd s1, 568(a0)\n"
"  sd s2, 576(a0)\n"
"  sd s3, 584(a0)\n"
"  sd s4, 592(a0)\n"
"  sd s5, 600(a0)\n"
"  sd s6, 608(a0)\n"
"  sd s7, 616(a0)\n"
"  sd s8, 624(a0)\n"
"  sd s9, 632(a0)\n"
"  sd s10, 640(a0)\n"
"  sd s11, 648(a0)\n"
"  fsd fs0, 656(a0)\n"
"  fsd fs1, 664(a0)\n"
"  fsd fs2, 672(a0)\n"
"  fsd fs3, 680(a0)\n"
"  fsd fs4, 688(a0)\n"
"  fsd fs5, 696(a0)\n"
"  fsd fs6, 704(a0)\n"
"  fsd fs7, 712(a0)\n"
"  fsd fs8, 720(a0)\n"
"  fsd fs9, 728(a0)\n"
"  fsd fs10, 736(a0)\n"
"  fsd fs11, 744(a0)\n"
"  frcsr t0\n  sd t0, 752(a0)\n"
    "  csrw sscratch, a0\n"
    "  ld t0, 0(a0)\n  csrw sepc, t0\n"
    "  li t0, 0x100\n  csrc sstatus, t0\n" // SPP = user
    "  li t0, 0x20\n  csrs sstatus, t0\n"  // SPIE: interrupts on once there
    "  ld t0, 520(a0)\n  csrw satp, t0\n  sfence.vma zero, zero\n"
    "  ld t0, 512(a0)\n  fscsr t0\n"
"  fld f0, 256(a0)\n"
"  fld f1, 264(a0)\n"
"  fld f2, 272(a0)\n"
"  fld f3, 280(a0)\n"
"  fld f4, 288(a0)\n"
"  fld f5, 296(a0)\n"
"  fld f6, 304(a0)\n"
"  fld f7, 312(a0)\n"
"  fld f8, 320(a0)\n"
"  fld f9, 328(a0)\n"
"  fld f10, 336(a0)\n"
"  fld f11, 344(a0)\n"
"  fld f12, 352(a0)\n"
"  fld f13, 360(a0)\n"
"  fld f14, 368(a0)\n"
"  fld f15, 376(a0)\n"
"  fld f16, 384(a0)\n"
"  fld f17, 392(a0)\n"
"  fld f18, 400(a0)\n"
"  fld f19, 408(a0)\n"
"  fld f20, 416(a0)\n"
"  fld f21, 424(a0)\n"
"  fld f22, 432(a0)\n"
"  fld f23, 440(a0)\n"
"  fld f24, 448(a0)\n"
"  fld f25, 456(a0)\n"
"  fld f26, 464(a0)\n"
"  fld f27, 472(a0)\n"
"  fld f28, 480(a0)\n"
"  fld f29, 488(a0)\n"
"  fld f30, 496(a0)\n"
"  fld f31, 504(a0)\n"
"  ld x1, 8(a0)\n"
"  ld x2, 16(a0)\n"
"  ld x3, 24(a0)\n"
"  ld x4, 32(a0)\n"
"  ld x5, 40(a0)\n"
"  ld x6, 48(a0)\n"
"  ld x7, 56(a0)\n"
"  ld x8, 64(a0)\n"
"  ld x9, 72(a0)\n"
"  ld x11, 88(a0)\n"
"  ld x12, 96(a0)\n"
"  ld x13, 104(a0)\n"
"  ld x14, 112(a0)\n"
"  ld x15, 120(a0)\n"
"  ld x16, 128(a0)\n"
"  ld x17, 136(a0)\n"
"  ld x18, 144(a0)\n"
"  ld x19, 152(a0)\n"
"  ld x20, 160(a0)\n"
"  ld x21, 168(a0)\n"
"  ld x22, 176(a0)\n"
"  ld x23, 184(a0)\n"
"  ld x24, 192(a0)\n"
"  ld x25, 200(a0)\n"
"  ld x26, 208(a0)\n"
"  ld x27, 216(a0)\n"
"  ld x28, 224(a0)\n"
"  ld x29, 232(a0)\n"
"  ld x30, 240(a0)\n"
"  ld x31, 248(a0)\n"
"  ld x10, 80(a0)\n"
    "  sret\n"
    ".balign 4\n"
    "user_trap:\n" // sp = the frame, sscratch = the process's sp
"  sd x1, 8(sp)\n"
"  sd x3, 24(sp)\n"
"  sd x4, 32(sp)\n"
"  sd x5, 40(sp)\n"
"  sd x6, 48(sp)\n"
"  sd x7, 56(sp)\n"
"  sd x8, 64(sp)\n"
"  sd x9, 72(sp)\n"
"  sd x10, 80(sp)\n"
"  sd x11, 88(sp)\n"
"  sd x12, 96(sp)\n"
"  sd x13, 104(sp)\n"
"  sd x14, 112(sp)\n"
"  sd x15, 120(sp)\n"
"  sd x16, 128(sp)\n"
"  sd x17, 136(sp)\n"
"  sd x18, 144(sp)\n"
"  sd x19, 152(sp)\n"
"  sd x20, 160(sp)\n"
"  sd x21, 168(sp)\n"
"  sd x22, 176(sp)\n"
"  sd x23, 184(sp)\n"
"  sd x24, 192(sp)\n"
"  sd x25, 200(sp)\n"
"  sd x26, 208(sp)\n"
"  sd x27, 216(sp)\n"
"  sd x28, 224(sp)\n"
"  sd x29, 232(sp)\n"
"  sd x30, 240(sp)\n"
"  sd x31, 248(sp)\n"
"  csrr t0, sscratch\n  sd t0, 16(sp)\n"
    "  csrw sscratch, zero\n"
    "  csrr t0, sepc\n  sd t0, 0(sp)\n"
    "  csrr t0, scause\n  sd t0, 528(sp)\n"
    "  csrr t0, stval\n  sd t0, 536(sp)\n"
"  fsd f0, 256(sp)\n"
"  fsd f1, 264(sp)\n"
"  fsd f2, 272(sp)\n"
"  fsd f3, 280(sp)\n"
"  fsd f4, 288(sp)\n"
"  fsd f5, 296(sp)\n"
"  fsd f6, 304(sp)\n"
"  fsd f7, 312(sp)\n"
"  fsd f8, 320(sp)\n"
"  fsd f9, 328(sp)\n"
"  fsd f10, 336(sp)\n"
"  fsd f11, 344(sp)\n"
"  fsd f12, 352(sp)\n"
"  fsd f13, 360(sp)\n"
"  fsd f14, 368(sp)\n"
"  fsd f15, 376(sp)\n"
"  fsd f16, 384(sp)\n"
"  fsd f17, 392(sp)\n"
"  fsd f18, 400(sp)\n"
"  fsd f19, 408(sp)\n"
"  fsd f20, 416(sp)\n"
"  fsd f21, 424(sp)\n"
"  fsd f22, 432(sp)\n"
"  fsd f23, 440(sp)\n"
"  fsd f24, 448(sp)\n"
"  fsd f25, 456(sp)\n"
"  fsd f26, 464(sp)\n"
"  fsd f27, 472(sp)\n"
"  fsd f28, 480(sp)\n"
"  fsd f29, 488(sp)\n"
"  fsd f30, 496(sp)\n"
"  fsd f31, 504(sp)\n"
"  frcsr t0\n  sd t0, 512(sp)\n"
    "  csrw satp, zero\n  sfence.vma zero, zero\n"
    "  mv a0, sp\n"
"  ld ra, 544(a0)\n"
"  ld sp, 552(a0)\n"
"  ld s0, 560(a0)\n"
"  ld s1, 568(a0)\n"
"  ld s2, 576(a0)\n"
"  ld s3, 584(a0)\n"
"  ld s4, 592(a0)\n"
"  ld s5, 600(a0)\n"
"  ld s6, 608(a0)\n"
"  ld s7, 616(a0)\n"
"  ld s8, 624(a0)\n"
"  ld s9, 632(a0)\n"
"  ld s10, 640(a0)\n"
"  ld s11, 648(a0)\n"
"  fld fs0, 656(a0)\n"
"  fld fs1, 664(a0)\n"
"  fld fs2, 672(a0)\n"
"  fld fs3, 680(a0)\n"
"  fld fs4, 688(a0)\n"
"  fld fs5, 696(a0)\n"
"  fld fs6, 704(a0)\n"
"  fld fs7, 712(a0)\n"
"  fld fs8, 720(a0)\n"
"  fld fs9, 728(a0)\n"
"  fld fs10, 736(a0)\n"
"  fld fs11, 744(a0)\n"
"  ld t0, 752(a0)\n  fscsr t0\n"
    "  ld a0, 528(a0)\n"
    "  ret\n");

#define CSR_READ(r) ({ uint64_t v_; __asm__ volatile("csrr %0, " #r : "=r"(v_)); v_; })
#define CSR_SET(r, v) __asm__ volatile("csrs " #r ", %0" ::"r"((uint64_t)(v)))
#define CSR_CLEAR(r, v) __asm__ volatile("csrc " #r ", %0" ::"r"((uint64_t)(v)))
#define CSR_WRITE(r, v) __asm__ volatile("csrw " #r ", %0" ::"r"((uint64_t)(v)))

// QEMU virt
#define UART 0x10000000ul
#define PLIC 0x0c000000ul
#define UART_IRQ 10
#define TEST_DEV 0x100000ul // "sifive,test": write to power off or reboot

// ---- SBI (calls into OpenSBI) ----

static long sbi(long ext, long fn, long a0, long a1) {
    register long x10 __asm__("a0") = a0, x11 __asm__("a1") = a1;
    register long x16 __asm__("a6") = fn, x17 __asm__("a7") = ext;
    __asm__ volatile("ecall" : "+r"(x10), "+r"(x11) : "r"(x16), "r"(x17) : "memory");
    return x10;
}

static uint64_t rdtime(void) {
    uint64_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}

// ---- power ----

_Noreturn void kexit(int code) {
    // the test device: 0x5555 = pass, (code << 16) | 0x3333 = fail with `code` (QEMU exits with it)
    REG32(TEST_DEV) = code == 0 ? 0x5555u : ((uint32_t)code << 16) | 0x3333u;
    sbi(0x53525354, 0, 0, code != 0); // SBI system reset, in case there is no test device
    for (;;) __asm__ volatile("wfi");
}


void st_k_reboot(void) {
    REG32(TEST_DEV) = 0x7777u;
    sbi(0x53525354, 0, 1, 0);
    for (;;) __asm__ volatile("wfi");
}

// ---- console: a 16550 UART ----

static void arch_putc(char c) {
    while (!(REG8(UART + 5) & 0x20)) {} // transmit holding register empty
    REG8(UART) = (uint8_t)c;
}

static void arch_wait(void) { __asm__ volatile("wfi"); }


static void uart_drain(void) {
    while (REG8(UART + 5) & 0x01) { // data ready
        uint8_t c = REG8(UART);
        uint32_t next = (rx_head + 1) % sizeof rx;
        if (next != rx_tail) rx[rx_head] = c, rx_head = next;
    }
}

// ---- the device tree (from OpenSBI in a1): RAM size and the timer frequency ----

static uint64_t ram_base = 0x80000000ul;
static uint32_t be32(const void *p) {
    const uint8_t *b = p;
    return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
}

static void read_dtb(const uint8_t *dtb) {
    if (!dtb || be32(dtb) != 0xd00dfeed) return;
    const uint8_t *st = dtb + be32(dtb + 8), *strs = dtb + be32(dtb + 12);
    char node[64] = "";
    int depth = 0, mem_depth = -1, cpus_depth = -1;
    for (const uint8_t *p = st;;) {
        uint32_t tok = be32(p);
        p += 4;
        if (tok == 1) { // begin node
            const char *name = (const char *)p;
            size_t n = strlen(name);
            depth++;
            if (n < sizeof node) memcpy(node, name, n + 1);
            if (!strncmp(name, "memory@", 7) || !strcmp(name, "memory")) mem_depth = depth;
            if (!strcmp(name, "cpus")) cpus_depth = depth;
            p += (n + 4) & ~3ul;
        } else if (tok == 2) { // end node
            if (depth == mem_depth) mem_depth = -1;
            if (depth == cpus_depth) cpus_depth = -1;
            depth--;
        } else if (tok == 3) { // property
            uint32_t len = be32(p), off = be32(p + 4);
            const uint8_t *val = p + 8;
            const char *pname = (const char *)strs + off;
            if (depth == mem_depth && !strcmp(pname, "reg") && len >= 16) {
                ram_base = (uint64_t)be32(val) << 32 | be32(val + 4);
                ram_size = (uint64_t)be32(val + 8) << 32 | be32(val + 12);
            }
            if (depth == cpus_depth && !strcmp(pname, "timebase-frequency") && len >= 4) timebase = be32(val);
            p += 8 + ((len + 3) & ~3u);
        } else if (tok == 4) { // nop
        } else break;
    }
}

// Roots: the globals, the stack (from the deepest frame up) and the callee-saved registers, which
// gc_roots spills onto the stack before scanning it.
static void gc_roots(void) {
    uint64_t regs[13];
    __asm__ volatile("sd s0, 0(%0)\n sd s1, 8(%0)\n sd s2, 16(%0)\n sd s3, 24(%0)\n sd s4, 32(%0)\n sd s5, 40(%0)\n"
                     "sd s6, 48(%0)\n sd s7, 56(%0)\n sd s8, 64(%0)\n sd s9, 72(%0)\n sd s10, 80(%0)\n sd s11, 88(%0)\n"
                     "sd ra, 96(%0)" ::"r"(regs)
                     : "memory");
    gc_scan((uintptr_t)&__data_start, (uintptr_t)&__bss_end);
    gc_scan((uintptr_t)regs, (uintptr_t)&__stack_top);
    gc_runs++;
}

const char *st_k_arch(void) { return "riscv64"; }
// what only x86 has
int64_t st_k_in(int64_t port, int64_t size) { (void)port, (void)size; return -1; }
void st_k_out(int64_t port, int64_t size, int64_t v) { (void)port, (void)size, (void)v; }
int64_t st_k_ps2_read(void) { return -1; }
int64_t st_k_ps2_mouse(void) { return 0; }
int64_t st_k_fb(int64_t what) { (void)what; return 0; }
int64_t st_k_hw_random(void) { return -1; }

// The real time: QEMU's goldfish RTC (nanoseconds since 1970; reading the low half latches the high).
int64_t st_k_rtc_ms(void) {
    uint64_t lo = REG32(0x101000), hi = REG32(0x101004);
    return (int64_t)((hi << 32 | lo) / 1000000);
}

int64_t st_k_kernel_size(void) { return (int64_t)((uintptr_t)&__kernel_end - 0x80200000ul); }

// ---- time ----

static void timer_arm(void) { sbi(0x54494D45, 0, (long)(rdtime() + timebase / TICK_HZ), 0); }

// ---- interrupts ----

static volatile uint64_t irq_counts[64];
static volatile uint64_t plic_counts[128];

static const char *trap_name(uint64_t c) {
    static const char *names[] = {"instruction address misaligned", "instruction access fault", "illegal instruction",
                                  "breakpoint", "load address misaligned", "load access fault",
                                  "store address misaligned", "store access fault", "environment call from user mode",
                                  "environment call from supervisor mode", "", "", "instruction page fault",
                                  "load page fault", "", "store page fault"};
    return c < 16 && names[c][0] ? names[c] : "unknown exception";
}

void st_trap(uint64_t cause, uint64_t epc, uint64_t tval, uint64_t *frame) {
    (void)frame;
    if ((int64_t)cause < 0) {
        uint64_t code = cause & 63;
        irq_counts[code]++;
        if (code == 5) { // supervisor timer
            ticks++;
            timer_arm();
        } else if (code == 9) { // supervisor external: ask the PLIC which device
            uint32_t irq = REG32(PLIC + 0x201004);
            if (irq == UART_IRQ) uart_drain();
            if (irq >= 1 && irq <= 8) { // virtio-mmio: acknowledge it at the device, or it fires again
                uintptr_t dev = 0x10001000ul + (irq - 1) * 0x1000ul;
                REG32(dev + 0x64) = REG32(dev + 0x60);
            }
            if (irq && irq < 128) plic_counts[irq]++;
            if (irq) REG32(PLIC + 0x201004) = irq;
        }
        return;
    }
    // an exception in the kernel: there is no one to hand it to
    printf("\n*** kernel panic: %s (scause %llu)\n    at pc 0x%llx, address 0x%llx\n", trap_name(cause),
           (unsigned long long)cause, (unsigned long long)epc, (unsigned long long)tval);
    kexit(101);
}

int64_t st_k_irqs(int64_t which) { return which >= 0 && which < 64 ? (int64_t)irq_counts[which] : 0; }

extern uint64_t user_enter(uint64_t *frame);

// Run a process (its frame) for up to `ms` milliseconds. Returns scause when it traps (8: a
// system call; a fault), -1 when its time is up and -2 when a device interrupt wants the kernel.
int64_t st_k_user_run(int64_t frame, int64_t ms) {
    uint64_t *f = (uint64_t *)frame;
    uint64_t until = rdtime() + (uint64_t)ms * (timebase / 1000);
    for (;;) {
        uint64_t cause = user_enter(f);
        if ((int64_t)cause >= 0) {
            CSR_SET(sstatus, 1u << 1);
            return (int64_t)cause;
        }
        st_trap(cause, f[0], f[67], NULL);
        CSR_SET(sstatus, 1u << 1);
        if ((cause & 63) == 9) return -2;
        if (rdtime() >= until) return -1;
    }
}

// Device interrupts for drivers written in stellang: turn a PLIC source on, then watch its count
// grow (the handler only counts and acknowledges it; the driver does the rest from the main loop).

void st_k_irq_enable(int64_t irq) {
    if (irq <= 0 || irq >= 128) return;
    REG32(PLIC + 4 * irq) = 1;
    REG32(PLIC + 0x2080 + 4 * (irq / 32)) |= 1u << (irq % 32);
}

int64_t st_k_irq_count(int64_t irq) { return irq > 0 && irq < 128 ? (int64_t)plic_counts[irq] : 0; }

// ---- start ----

int main(void); // the program's entry (generated by the compiler)

void kmain(uint64_t hart, const uint8_t *dtb) {
    (void)hart;
    read_dtb(dtb);
    heap_next = heap_start = (uintptr_t)&__kernel_end;
    heap_end = ram_base + ram_size;

    // the console: 8 bits, FIFOs on, interrupt on "data ready"
    REG8(UART + 3) = 0x03;
    REG8(UART + 2) = 0x07;
    REG8(UART + 1) = 0x01;

    // interrupts: the UART through the PLIC (hart 0, supervisor context = 1), and the timer
    CSR_WRITE(sscratch, 0);
    CSR_WRITE(stvec, (uintptr_t)trap_vector);
    REG32(PLIC + 4 * UART_IRQ) = 1;
    REG32(PLIC + 0x2080) = 1u << UART_IRQ;
    REG32(PLIC + 0x201000) = 0;
    CSR_SET(sie, (1u << 9) | (1u << 5)); // external, timer
    timer_arm();
    CSR_SET(sstatus, 1u << 1); // SIE

    kexit(main());
}
