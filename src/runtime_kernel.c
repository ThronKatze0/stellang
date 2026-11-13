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

// A copy of the console output for a terminal window (st_k_console_take), when one is open.
static char con_buf[1 << 16];
static uint32_t con_len;
static bool con_capture;

void kputs(const char *s, size_t n) {
    if (con_capture) {
        for (size_t i = 0; i < n && con_len < sizeof con_buf; i++) con_buf[con_len++] = s[i];
    }
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
// Bytes as text, for data from outside (the network): NUL bytes become spaces so they can't cut a
// string short.
char *st_k_read_text(int64_t src, int64_t n) {
    char *r = st_k_read_str(src, n);
    for (int64_t i = 0; i < n; i++) if (!r[i]) r[i] = ' ';
    return r;
}
// The Internet checksum's ones'-complement sum of `n` bytes (big-endian 16-bit words), added to `sum`
// and folded to 16 bits. The callers check the range first.
int64_t st_k_csum(int64_t addr, int64_t n, int64_t sum) {
    const uint8_t *p = (const uint8_t *)addr;
    uint64_t s = (uint64_t)sum;
    for (int64_t i = 0; i + 1 < n; i += 2) s += (uint64_t)p[i] << 8 | p[i + 1];
    if (n & 1) s += (uint64_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (int64_t)s;
}
// The clock in its finest steps (for timing jitter as a little entropy).
int64_t st_k_cycles(void) { return (int64_t)rdtime(); }
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
#define TICK_HZ 1000

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

// ---- 2D drawing (std/gfx.st) ----
//
// Everything draws into the current target (a surface: 32-bit 0x00RRGGBB pixels, row after row),
// clipped to its clip rectangle. Colors are 0xRRGGBB; `alpha` is 0 (invisible) .. 255 (opaque).
// Text uses the anti-aliased faces in runtime_font.c.

static uint32_t *g_px;
static int64_t g_w, g_h, g_cx0, g_cy0, g_cx1, g_cy1;

// Memory for a surface (or any buffer of plain bytes) from the garbage-collected heap: zeroed,
// and freed once no value holds its address any more.
int64_t st_k_alloc(int64_t bytes) { return (int64_t)(uintptr_t)GC_malloc_atomic(bytes > 0 ? (size_t)bytes : 1); }

void st_g_target(int64_t base, int64_t w, int64_t h) {
    g_px = (uint32_t *)(uintptr_t)base;
    g_w = w, g_h = h;
    g_cx0 = g_cy0 = 0, g_cx1 = w, g_cy1 = h;
}

// Clip to a rectangle (inside the surface); further drawing stays in it.
void st_g_clip(int64_t x, int64_t y, int64_t w, int64_t h) {
    g_cx0 = x < 0 ? 0 : x, g_cy0 = y < 0 ? 0 : y;
    g_cx1 = x + w > g_w ? g_w : x + w, g_cy1 = y + h > g_h ? g_h : y + h;
}

static inline uint32_t mixpx(uint32_t d, uint32_t s, uint32_t a) { // a: 0..256
    uint32_t rb = ((s & 0xff00ff) * a + (d & 0xff00ff) * (256 - a)) >> 8;
    uint32_t g = ((s & 0x00ff00) * a + (d & 0x00ff00) * (256 - a)) >> 8;
    return (rb & 0xff00ff) | (g & 0x00ff00);
}

// clip a rectangle; false if nothing is left
static bool g_clipr(int64_t *x, int64_t *y, int64_t *w, int64_t *h) {
    int64_t x0 = *x < g_cx0 ? g_cx0 : *x, y0 = *y < g_cy0 ? g_cy0 : *y;
    int64_t x1 = *x + *w > g_cx1 ? g_cx1 : *x + *w, y1 = *y + *h > g_cy1 ? g_cy1 : *y + *h;
    if (!g_px || x1 <= x0 || y1 <= y0) return false;
    *x = x0, *y = y0, *w = x1 - x0, *h = y1 - y0;
    return true;
}

void st_g_fill(int64_t x, int64_t y, int64_t w, int64_t h, int64_t color) {
    if (!g_clipr(&x, &y, &w, &h)) return;
    uint32_t c = (uint32_t)color & 0xffffff;
    for (int64_t r = 0; r < h; r++) {
        uint32_t *p = g_px + (y + r) * g_w + x;
        for (int64_t i = 0; i < w; i++) p[i] = c;
    }
}

void st_g_blend(int64_t x, int64_t y, int64_t w, int64_t h, int64_t color, int64_t alpha) {
    if (alpha >= 255) { st_g_fill(x, y, w, h, color); return; }
    if (alpha <= 0 || !g_clipr(&x, &y, &w, &h)) return;
    uint32_t c = (uint32_t)color, a = (uint32_t)alpha + 1;
    for (int64_t r = 0; r < h; r++) {
        uint32_t *p = g_px + (y + r) * g_w + x;
        for (int64_t i = 0; i < w; i++) p[i] = mixpx(p[i], c, a);
    }
}

static inline void g_plot(int64_t x, int64_t y, uint32_t c, uint32_t a) { // a: 0..256
    if (x < g_cx0 || y < g_cy0 || x >= g_cx1 || y >= g_cy1 || !a) return;
    uint32_t *p = g_px + y * g_w + x;
    *p = a >= 256 ? c : mixpx(*p, c, a);
}

void st_g_pixel(int64_t x, int64_t y, int64_t color) { if (g_px) g_plot(x, y, (uint32_t)color & 0xffffff, 256); }

int64_t st_g_get(int64_t x, int64_t y) {
    if (!g_px || x < 0 || y < 0 || x >= g_w || y >= g_h) return 0;
    return g_px[y * g_w + x];
}

// A rectangle with rounded corners (radius r), its edges anti-aliased.
void st_g_round(int64_t x, int64_t y, int64_t w, int64_t h, int64_t r, int64_t color, int64_t alpha) {
    if (w <= 0 || h <= 0 || alpha <= 0) return;
    if (r * 2 > w) r = w / 2;
    if (r * 2 > h) r = h / 2;
    if (r <= 0) { st_g_blend(x, y, w, h, color, alpha); return; }
    st_g_blend(x, y + r, w, h - 2 * r, color, alpha);
    uint32_t c = (uint32_t)color & 0xffffff;
    for (int64_t j = 0; j < r; j++) {
        // rows of the top and bottom bands: full in the middle, coverage at the corners
        st_g_blend(x + r, y + j, w - 2 * r, 1, color, alpha);
        st_g_blend(x + r, y + h - 1 - j, w - 2 * r, 1, color, alpha);
        for (int64_t i = 0; i < r; i++) {
            double dx = r - i - 0.5, dy = r - j - 0.5;
            double cov = (double)r - sqrt(dx * dx + dy * dy) + 0.5;
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            uint32_t a = (uint32_t)(cov * (double)(alpha + 1));
            g_plot(x + i, y + j, c, a);
            g_plot(x + w - 1 - i, y + j, c, a);
            g_plot(x + i, y + h - 1 - j, c, a);
            g_plot(x + w - 1 - i, y + h - 1 - j, c, a);
        }
    }
}

// A filled circle, anti-aliased.
void st_g_circle(int64_t cx, int64_t cy, int64_t r, int64_t color, int64_t alpha) {
    if (r <= 0 || alpha <= 0 || !g_px) return;
    uint32_t c = (uint32_t)color & 0xffffff;
    for (int64_t y = -r; y < r; y++) {
        for (int64_t x = -r; x < r; x++) {
            double dx = x + 0.5, dy = y + 0.5;
            double cov = (double)r - sqrt(dx * dx + dy * dy) + 0.5;
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            g_plot(cx + x, cy + y, c, (uint32_t)(cov * (double)(alpha + 1)));
        }
    }
}

// A line `width` pixels wide (Bresenham, with square pens).
void st_g_line(int64_t x0, int64_t y0, int64_t x1, int64_t y1, int64_t width, int64_t color) {
    if (!g_px) return;
    int64_t dx = x1 > x0 ? x1 - x0 : x0 - x1, dy = y1 > y0 ? y0 - y1 : y1 - y0;
    int64_t sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, e = dx + dy, k = width > 1 ? width : 1;
    for (int n = 0; n < 1 << 20; n++) {
        if (k == 1) g_plot(x0, y0, (uint32_t)color & 0xffffff, 256);
        else st_g_fill(x0 - k / 2, y0 - k / 2, k, k, color);
        if (x0 == x1 && y0 == y1) break;
        int64_t e2 = 2 * e;
        if (e2 >= dy) e += dy, x0 += sx;
        if (e2 <= dx) e += dx, y0 += sy;
    }
}

// Copy a w x h block from surface `src` (sw x sh) at (sx, sy) to (dx, dy). mode 0: copy;
// mode 1: blend by the source's top byte (0 = see-through, 255 = solid); mode 2: skip the pixels
// equal to `key` (sprites). Scaled by `scale` (whole pixels: pixel art stays sharp).
void st_g_blit(int64_t src, int64_t sw, int64_t sh, int64_t sx, int64_t sy, int64_t w, int64_t h, int64_t dx,
               int64_t dy, int64_t mode, int64_t key, int64_t scale) {
    if (!g_px || !src) return;
    if (scale < 1) scale = 1;
    if (sx < 0) w += sx, dx -= sx * scale, sx = 0;
    if (sy < 0) h += sy, dy -= sy * scale, sy = 0;
    if (sx + w > sw) w = sw - sx;
    if (sy + h > sh) h = sh - sy;
    if (w <= 0 || h <= 0) return;
    int64_t x = dx, y = dy, cw = w * scale, ch = h * scale;
    if (!g_clipr(&x, &y, &cw, &ch)) return;
    const uint32_t *s = (const uint32_t *)(uintptr_t)src;
    for (int64_t r = 0; r < ch; r++) {
        const uint32_t *row = s + (sy + (y - dy + r) / scale) * sw + sx;
        uint32_t *p = g_px + (y + r) * g_w + x;
        if (mode == 0 && scale == 1) {
            memcpy(p, row + (x - dx), (size_t)cw * 4);
            continue;
        }
        for (int64_t i = 0; i < cw; i++) {
            uint32_t v = row[(x - dx + i) / scale];
            if (mode == 0) p[i] = v;
            else if (mode == 2) { if ((v & 0xffffff) != ((uint32_t)key & 0xffffff)) p[i] = v & 0xffffff; }
            else {
                uint32_t a = v >> 24;
                if (a) p[i] = a == 255 ? v & 0xffffff : mixpx(p[i], v, a + 1);
            }
        }
    }
}

#define NFACE_OK(f) ((f) >= 0 && (f) < NFACES)

static const Glyph *g_glyph(const Face *f, uint32_t cp) {
    int lo = 0, hi = f->n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (f->g[mid].cp == cp) return &f->g[mid];
        if (f->g[mid].cp < cp) lo = mid + 1;
        else hi = mid - 1;
    }
    return cp == '?' ? NULL : g_glyph(f, '?');
}

static uint32_t utf8_next(const unsigned char **s) {
    const unsigned char *p = *s;
    uint32_t c = *p++;
    int more = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
    if (more) c &= 0x3f >> more;
    while (more-- && (*p & 0xc0) == 0x80) c = (c << 6) | (*p++ & 0x3f);
    *s = p;
    return c;
}

// Text in face `face`, its line's top at y. Returns the width it took.
int64_t st_g_text(int64_t x, int64_t y, const char *s, int64_t color, int64_t face) {
    if (!NFACE_OK(face)) face = 0;
    const Face *f = &faces[face];
    uint32_t c = (uint32_t)color & 0xffffff;
    int64_t x0 = x, base = y + f->ascent;
    for (const unsigned char *p = (const unsigned char *)s; *p;) {
        const Glyph *g = g_glyph(f, utf8_next(&p));
        if (!g) continue;
        if (g_px && g->w) {
            int64_t gx = x + g->x, gy = base + g->y;
            if (gx < g_cx1 && gy < g_cy1 && gx + g->w > g_cx0 && gy + g->h > g_cy0) {
                const uint8_t *a = f->a + g->off;
                for (int r = 0; r < g->h; r++)
                    for (int i = 0; i < g->w; i++) {
                        uint8_t v = a[r * g->w + i];
                        if (v) g_plot(gx + i, gy + r, c, v + 1u);
                    }
            }
        }
        x += g->adv;
    }
    return x - x0;
}

int64_t st_g_text_width(const char *s, int64_t face) {
    if (!NFACE_OK(face)) face = 0;
    int64_t w = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p;) {
        const Glyph *g = g_glyph(&faces[face], utf8_next(&p));
        if (g) w += g->adv;
    }
    return w;
}

// What: 0 ascent, 1 descent, 2 line height.
int64_t st_g_font(int64_t face, int64_t what) {
    if (!NFACE_OK(face)) face = 0;
    const Face *f = &faces[face];
    return what == 0 ? f->ascent : what == 1 ? f->descent : f->ascent + f->descent;
}

// ---- the console for a terminal window ----

// Keep a copy of what's printed (on), and hand it over (take).
void st_k_console_capture(bool on) { con_capture = on; }
char *st_k_console_take(void) {
    char *r = GC_malloc_atomic(con_len + 1);
    memcpy(r, con_buf, con_len);
    con_len = 0;
    return r;
}

// Type a byte, as if it came over the serial line.
void st_k_inject(int64_t b) {
    uint32_t next = (rx_head + 1) % sizeof rx;
    if (next != rx_tail) rx[rx_head] = (uint8_t)b, rx_head = next;
}

// ---- `import web` on bare metal: JSX apps in windows ----
//
// The window system (in stellang) renders each app in its own context: the state cells of its
// signals and the event handlers of its last render. Handlers come back by number, as in the browser.

typedef struct {
    Vec *hooks, *handlers, *arities;
    int64_t hook_i;
} UiCtx;

static UiCtx *ui_cur;
static bool ui_dirty;

#define AT(t, i) (((void **)(t)->data)[i])
static int64_t table_add(Vec **t, void *x) {
    if (!*t) *t = st_vec_new(0, sizeof(void *), 0);
    if ((*t)->len == (*t)->cap) st_vec_grow(*t, sizeof(void *));
    AT(*t, (*t)->len) = x;
    return (*t)->len++;
}

int64_t st_k_ui_new(void) { return (int64_t)(uintptr_t)GC_malloc(sizeof(UiCtx)); }

// Render `app` in context `ctx`: its HTML.
char *st_k_ui_render(int64_t ctx, Closure app) {
    UiCtx *c = (UiCtx *)(uintptr_t)ctx, *was = ui_cur;
    if (c->handlers) c->handlers->len = c->arities->len = 0;
    c->hook_i = 0;
    ui_cur = c;
    char *html = ((char *(*)(Closure))FN(app))(app);
    ui_cur = was;
    return html;
}

// Call handler `id` of the context's last render, with `value` if it takes one.
void st_k_ui_dispatch(int64_t ctx, int64_t id, const char *value) {
    UiCtx *c = (UiCtx *)(uintptr_t)ctx;
    if (!c || !c->handlers || id < 0 || id >= (int64_t)c->handlers->len) return;
    Closure f = AT(c->handlers, id);
    if ((intptr_t)AT(c->arities, id) == 1) ((void (*)(Closure, const char *))FN(f))(f, value);
    else ((void (*)(Closure))FN(f))(f);
}

// Whether some signal changed since the last call.
bool st_k_ui_dirty(void) {
    bool d = ui_dirty;
    ui_dirty = false;
    return d;
}

void **st_hook(void) {
    UiCtx *c = ui_cur;
    if (!c) return GC_malloc(sizeof(void *));
    if (!c->hooks || c->hook_i == (int64_t)c->hooks->len) table_add(&c->hooks, GC_malloc(sizeof(void *)));
    return AT(c->hooks, c->hook_i++);
}

int64_t st_on(Closure f, int64_t arity) {
    if (!ui_cur) return -1;
    table_add(&ui_cur->arities, (void *)(intptr_t)arity);
    return table_add(&ui_cur->handlers, f);
}

void st_invalidate(void) { ui_dirty = true; }

void st_mount(const char *selector, Closure app) {
    (void)selector, (void)app;
    st_panic("panic: web.mount: on StellaOS an app opens in a window (see examples/stellaos/wm.st)\n");
}
int64_t st_timer(Closure f, int64_t ms, int64_t repeat) { return st_k_timer(f, ms, repeat); }
void st_clear_timer(int64_t id) { st_k_cancel(id); }
void st_fetch(const char *m, const char *u, const char *b, Closure done) {
    (void)m, (void)u, (void)b;
    ((void (*)(Closure, int64_t, const char *))FN(done))(done, 0, "no network yet");
}

// web.save/load: kept in memory until the machine stops
static Vec *store_keys, *store_vals;
char *st_storage_get(const char *key) {
    for (size_t i = 0; store_keys && i < store_keys->len; i++)
        if (!strcmp(AT(store_keys, i), key)) return AT(store_vals, i);
    return "";
}
void st_storage_set(const char *key, const char *value) {
    for (size_t i = 0; store_keys && i < store_keys->len; i++)
        if (!strcmp(AT(store_keys, i), key)) { AT(store_vals, i) = (void *)value; return; }
    table_add(&store_keys, (void *)key);
    table_add(&store_vals, (void *)value);
}
char *st_location(void) { return "/"; }
void st_navigate(const char *path) { (void)path; }
void st_set_title(const char *t) { (void)t; }
const char *st_raw(const char *html) { return html; }
char *st_element_text(const char *id) { (void)id; return ""; }

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
