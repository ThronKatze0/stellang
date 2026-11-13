// stellang on bare metal (`stellang --kernel`): boot, interrupts, the console, timers and memory for
// a RISC-V 64 kernel on QEMU's `virt` machine (OpenSBI loads us at 0x80200000 in supervisor mode).
// Appended after runtime_klibc.c, runtime.c and runtime_gc.c; std/kernel.st is the stellang side.
//
//   boot      _start: zero .bss, set the stack, turn on the FPU, then kmain -> the program's main()
//   traps     timer ticks (SBI), the UART's "byte received" through the PLIC; exceptions panic
//   memory    the GC's pages come from the RAM after the kernel (its size from the device tree);
//             collections happen when allocating, scanning globals, the stack and saved registers
//   timers    after/every closures run from the main loop (st_k_idle and the blocking waits), never
//             from an interrupt, so interrupt handlers never allocate
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

extern char __data_start, __bss_end, __stack_top, __kernel_end;
extern void trap_vector(void);

#define REG8(a) (*(volatile uint8_t *)(uintptr_t)(a))
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
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

void st_k_shutdown(int64_t code) {
    fflush(stdout);
    kexit((int)code);
}

void st_k_reboot(void) {
    REG32(TEST_DEV) = 0x7777u;
    sbi(0x53525354, 0, 1, 0);
    for (;;) __asm__ volatile("wfi");
}

// ---- console: a 16550 UART ----

static void uart_putc(char c) {
    while (!(REG8(UART + 5) & 0x20)) {} // transmit holding register empty
    REG8(UART) = (uint8_t)c;
}

void kputs(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\n') uart_putc('\r');
        uart_putc(s[i]);
    }
}

// received bytes, filled by the interrupt handler, drained by st_k_read_byte
static volatile uint8_t rx[1024];
static volatile uint32_t rx_head, rx_tail;

static void uart_drain(void) {
    while (REG8(UART + 5) & 0x01) { // data ready
        uint8_t c = REG8(UART);
        uint32_t next = (rx_head + 1) % sizeof rx;
        if (next != rx_tail) rx[rx_head] = c, rx_head = next;
    }
}

// ---- the device tree (from OpenSBI in a1): RAM size and the timer frequency ----

static uint64_t ram_base = 0x80000000ul, ram_size = 128ul << 20, timebase = 10000000;

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

// ---- memory: GC pages from the RAM after the kernel ----

static uintptr_t heap_next, heap_end;
static uint64_t gc_runs;
static size_t pages_out; // bytes handed out by st_k_alloc_pages

static void *gc_grow(uint32_t n) {
    uintptr_t a = (heap_next + PAGE - 1) & ~(uintptr_t)(PAGE - 1);
    size_t bytes = (size_t)n * PAGE;
    if (a + bytes > heap_end || a + bytes < a) {
        static const char m[] = "panic: out of memory\n";
        st_panic(m);
    }
    heap_next = a + bytes;
    memset((void *)a, 0, bytes);
    return (void *)a;
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

// Called before each allocation (runtime_gc.c, with GC_AUTO): collect when the heap has grown by
// as much as was live after the last collection (at least 1 MiB).
static void gc_maybe(void) {
    size_t limit = live_bytes < (1u << 20) ? (1u << 20) : live_bytes;
    if (since_gc > limit) gc_collect();
}

// Pages outside the GC (4 KiB each, zeroed, never moved or freed): for device buffers that hardware
// reads and writes directly (virtio queues, DMA, framebuffers). Returns the physical address.
int64_t st_k_alloc_pages(int64_t n) {
    if (n <= 0) return 0;
    uintptr_t a = (heap_next + 4095) & ~(uintptr_t)4095;
    size_t bytes = (size_t)n * 4096;
    if (a + bytes > heap_end || a + bytes < a) st_panic("panic: out of memory (alloc_pages)\n");
    heap_next = a + bytes;
    memset((void *)a, 0, bytes);
    pages_out += bytes;
    return (int64_t)a;
}

// Bulk memory, for drivers: copy, fill with a 32-bit value (pixels), strings in and out.
void st_k_copy(int64_t dst, int64_t src, int64_t n) { if (n > 0) memmove((void *)dst, (const void *)src, (size_t)n); }
void st_k_fill32(int64_t dst, int64_t count, int64_t v) {
    volatile uint32_t *p = (uint32_t *)dst;
    for (int64_t i = 0; i < count; i++) p[i] = (uint32_t)v;
}
void st_k_write_str(int64_t dst, const char *s) { memcpy((void *)dst, s, strlen(s)); }
char *st_k_read_str(int64_t src, int64_t n) {
    char *r = GC_malloc_atomic(n > 0 ? (size_t)n + 1 : 1);
    if (n > 0) memcpy(r, (const void *)src, (size_t)n);
    return r;
}
int64_t st_k_pages_out(void) { return (int64_t)pages_out; }

int64_t st_k_heap_live(void) { return (int64_t)live_bytes; }   // bytes in use after the last collection
int64_t st_k_heap_mapped(void) { return (int64_t)(heap_next - (uintptr_t)&__kernel_end - pages_out); } // GC pages taken
int64_t st_k_heap_free(void) { return (int64_t)(heap_end - heap_next); } // RAM not yet handed to the GC
int64_t st_k_ram_size(void) { return (int64_t)ram_size; }
int64_t st_k_kernel_size(void) { return (int64_t)((uintptr_t)&__kernel_end - 0x80200000ul); }
int64_t st_k_gc_runs(void) { return (int64_t)gc_runs; }
void st_k_gc(void) { gc_collect(); }

// ---- time ----

static volatile uint64_t ticks;
#define TICK_HZ 100

static void timer_arm(void) { sbi(0x54494D45, 0, (long)(rdtime() + timebase / TICK_HZ), 0); }

int64_t st_now_ms(void) { return (int64_t)(rdtime() / (timebase / 1000)); }
int64_t st_k_ticks(void) { return (int64_t)ticks; }

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

// ---- timers (closures; run from the main loop) ----

typedef void *Closure; // points at { fn, captures... }
#define FN(c) (*(void **)(c))
#define MAX_TIMERS 256

static Closure timer_fn[MAX_TIMERS]; // in .bss, so the GC sees them
static int64_t timer_due[MAX_TIMERS], timer_every[MAX_TIMERS];

int64_t st_k_timer(Closure f, int64_t ms, int64_t repeat) {
    for (int64_t i = 0; i < MAX_TIMERS; i++) {
        if (!timer_fn[i]) {
            timer_fn[i] = f;
            timer_due[i] = st_now_ms() + (ms < 0 ? 0 : ms);
            timer_every[i] = repeat ? (ms < 1 ? 1 : ms) : 0;
            return i;
        }
    }
    st_panic("panic: too many timers (256)\n");
}

void st_k_cancel(int64_t id) {
    if (id >= 0 && id < MAX_TIMERS) timer_fn[id] = NULL;
}

int64_t st_k_timers(void) {
    int64_t n = 0;
    for (int i = 0; i < MAX_TIMERS; i++) n += timer_fn[i] != NULL;
    return n;
}

// Run the timers that are due. Returns whether any ran.
static bool run_timers(void) {
    bool any = false;
    int64_t now = st_now_ms();
    for (int i = 0; i < MAX_TIMERS; i++) {
        Closure f = timer_fn[i];
        if (!f || timer_due[i] > now) continue;
        if (timer_every[i]) {
            timer_due[i] += timer_every[i];
            if (timer_due[i] <= now) timer_due[i] = now + timer_every[i]; // fell behind: don't burst
        } else {
            timer_fn[i] = NULL;
        }
        ((void (*)(Closure))FN(f))(f);
        any = true;
        now = st_now_ms();
    }
    return any;
}

// One turn of the event loop: run due timers, else sleep until the next interrupt.
void st_k_idle(void) {
    if (!run_timers() && rx_head == rx_tail) __asm__ volatile("wfi");
}

// A received byte, or -1 if none is waiting.
int64_t st_k_read_byte(void) {
    if (rx_head == rx_tail) return -1;
    uint8_t c = rx[rx_tail];
    rx_tail = (rx_tail + 1) % sizeof rx;
    return c;
}

// The next byte from the console, running timers while waiting.
int64_t st_k_wait_byte(void) {
    for (;;) {
        int64_t c = st_k_read_byte();
        if (c >= 0) return c;
        st_k_idle();
    }
}

void st_sleep(int64_t ms) { // the builtin `sleep(ms)`
    int64_t until = st_now_ms() + ms;
    while (st_now_ms() < until) st_k_idle();
}

// ---- raw memory (memory-mapped devices) ----

int64_t st_k_peek(int64_t addr, int64_t size) {
    switch (size) {
    case 1: return *(volatile uint8_t *)addr;
    case 2: return *(volatile uint16_t *)addr;
    case 4: return *(volatile uint32_t *)addr;
    default: return *(volatile int64_t *)addr;
    }
}

void st_k_poke(int64_t addr, int64_t size, int64_t v) {
    switch (size) {
    case 1: *(volatile uint8_t *)addr = (uint8_t)v; break;
    case 2: *(volatile uint16_t *)addr = (uint16_t)v; break;
    case 4: *(volatile uint32_t *)addr = (uint32_t)v; break;
    default: *(volatile int64_t *)addr = v;
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
    heap_next = (uintptr_t)&__kernel_end;
    heap_end = ram_base + ram_size;

    // the console: 8 bits, FIFOs on, interrupt on "data ready"
    REG8(UART + 3) = 0x03;
    REG8(UART + 2) = 0x07;
    REG8(UART + 1) = 0x01;

    // interrupts: the UART through the PLIC (hart 0, supervisor context = 1), and the timer
    CSR_WRITE(stvec, (uintptr_t)trap_vector);
    REG32(PLIC + 4 * UART_IRQ) = 1;
    REG32(PLIC + 0x2080) = 1u << UART_IRQ;
    REG32(PLIC + 0x201000) = 0;
    CSR_SET(sie, (1u << 9) | (1u << 5)); // external, timer
    timer_arm();
    CSR_SET(sstatus, 1u << 1); // SIE

    kexit(main());
}
