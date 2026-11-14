// stellang on bare metal: x86_64 PCs, booted by UEFI. boot_uefi.c (the loader, a UEFI application)
// leaves the firmware's boot services and jumps to _start with a BootInfo; we are in 64-bit mode
// with interrupts off. Comes after runtime_kernel.c (what every machine shares).
//
//   boot      our own stack, GDT, IDT and page tables (everything identity-mapped: RAM write-back,
//             the framebuffer write-combining, the rest uncached)
//   traps     the local APIC's timer, 1000 times a second; it also polls the serial line and the
//             PS/2 controller (keyboard, touchpad) into rings. Exceptions panic, on the screen too
//   memory    the largest free block of RAM in the firmware's memory map
//   time      the time stamp counter (its rate measured by the loader); the date from UEFI GetTime
//   power     UEFI ResetSystem
//   programs  RISC-V machine code (what cc.st makes), run by an interpreter (rv_run) with the same
//             frame and page tables proc.st sets up for real RISC-V hardware
//
// Nothing here writes to a disk: on a real computer, StellaOS lives in RAM.

typedef struct {
    uint64_t fb, fb_width, fb_height, fb_stride, fb_format;
    uint64_t mmap, mmap_size, mmap_desc;
    uint64_t runtime;
    uint64_t tsc_hz;
    uint64_t kernel, kernel_size;
} BootInfo;

static BootInfo boot;

__asm__(
    ".section .text.boot, \"ax\"\n"
    ".globl _start\n"
    "_start:\n"
    "  cli\n"
    "  lea __stack_top(%rip), %rsp\n"
    "  xor %ebp, %ebp\n"
    "  call kmain\n"
    "1: hlt\n"
    "  jmp 1b\n"
    ".text\n");

static inline void outb(uint16_t p, uint8_t v) { __asm__ volatile("outb %0, %1" ::"a"(v), "Nd"(p)); }
static inline uint8_t inb(uint16_t p) { uint8_t v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outl(uint16_t p, uint32_t v) { __asm__ volatile("outl %0, %1" ::"a"(v), "Nd"(p)); }
static inline uint32_t inl(uint16_t p) { uint32_t v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline uint64_t rdmsr(uint32_t m) {
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(m));
    return (uint64_t)hi << 32 | lo;
}
static inline void wrmsr(uint32_t m, uint64_t v) { __asm__ volatile("wrmsr" ::"c"(m), "a"((uint32_t)v), "d"((uint32_t)(v >> 32))); }
static inline void cpuid(uint32_t leaf, uint32_t r[4]) {
    __asm__ volatile("cpuid" : "=a"(r[0]), "=b"(r[1]), "=c"(r[2]), "=d"(r[3]) : "a"(leaf), "c"(0));
}

static uint64_t rdtime(void) {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return (uint64_t)hi << 32 | lo;
}

static void arch_wait(void) { __asm__ volatile("sti; hlt"); }

// Port I/O for drivers in stellang (PCI configuration space, ...).
int64_t st_k_in(int64_t port, int64_t size) {
    return size == 1 ? inb((uint16_t)port) : size == 4 ? inl((uint16_t)port) : -1;
}
void st_k_out(int64_t port, int64_t size, int64_t v) {
    if (size == 1) outb((uint16_t)port, (uint8_t)v);
    else if (size == 4) outl((uint16_t)port, (uint32_t)v);
}

// ---- UEFI runtime services: the clock and power ----

typedef struct {
    uint16_t year;
    uint8_t month, day, hour, minute, second, pad1;
    uint32_t nanosecond;
    int16_t zone;
    uint8_t daylight, pad2;
} EfiTime;

typedef struct {
    uint64_t hdr[3];
    uint64_t(__attribute__((ms_abi)) * get_time)(EfiTime *, void *);
    void *set_time, *get_wakeup, *set_wakeup, *set_virtual, *convert, *get_var, *get_next_var, *set_var;
    void *next_count;
    void(__attribute__((ms_abi)) * reset)(int type, uint64_t status, uint64_t size, void *data);
} EfiRuntime;

static int64_t epoch_ms_at_boot;
static uint64_t tsc_at_boot;

static int64_t days_from_civil(int64_t y, int64_t m, int64_t d) { // Howard Hinnant's
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400;
    int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
}

// Milliseconds since 1970 by the computer's clock (local time on PCs that also run Windows, UTC on
// most others: the firmware doesn't say which).
int64_t st_k_rtc_ms(void) { return epoch_ms_at_boot + (int64_t)((rdtime() - tsc_at_boot) / (timebase / 1000)); }

static void read_clock(void) {
    EfiRuntime *rt = (EfiRuntime *)boot.runtime;
    EfiTime t = {0};
    tsc_at_boot = rdtime();
    if (rt && !(rt->get_time(&t, 0) >> 63) && t.year >= 1970)
        epoch_ms_at_boot = (days_from_civil(t.year, t.month, t.day) * 86400 + t.hour * 3600 + t.minute * 60 + t.second) * 1000;
}

static bool fb_panic(const char *msg);

static bool in_vm(void) {
    uint32_t r[4];
    cpuid(1, r);
    return r[2] & (1u << 31);
}

_Noreturn void kexit(int code) {
    EfiRuntime *rt = (EfiRuntime *)boot.runtime;
    if (in_vm()) outb(0xf4, (uint8_t)code); // QEMU's isa-debug-exit, when there (exits with code*2+1)
    // a panic on a real screen: keep it there to be read
    else if (code != 0 && boot.fb) for (;;) __asm__ volatile("cli; hlt");
    if (rt) rt->reset(2 /* shutdown */, 0, 0, 0);
    for (;;) __asm__ volatile("cli; hlt");
}

void st_k_reboot(void) {
    EfiRuntime *rt = (EfiRuntime *)boot.runtime;
    if (rt) rt->reset(0 /* cold */, 0, 0, 0);
    outb(0x64, 0xfe); // the keyboard controller's reset line
    for (;;) __asm__ volatile("cli; hlt");
}

// ---- the serial line (COM1, if the machine has one; most laptops don't) ----

#define COM1 0x3f8
static bool has_serial;

static void arch_putc(char c) {
    if (!has_serial) return;
    for (int i = 0; i < 100000 && !(inb(COM1 + 5) & 0x20); i++) {}
    outb(COM1, (uint8_t)c);
}

static void serial_init(void) {
    outb(COM1 + 7, 0x5a);
    if (inb(COM1 + 7) != 0x5a) return;
    outb(COM1 + 1, 0x00); // no interrupts: the timer polls it
    outb(COM1 + 3, 0x80); // 115200 baud
    outb(COM1 + 0, 0x01);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8N1
    outb(COM1 + 2, 0x07); // FIFOs
    has_serial = true;
}

static void serial_poll(void) {
    if (!has_serial) return;
    for (int n = 0; n < 64 && (inb(COM1 + 5) & 1); n++) {
        uint8_t c = inb(COM1);
        uint32_t next = (rx_head + 1) % sizeof rx;
        if (next != rx_tail) rx[rx_head] = c, rx_head = next;
    }
}

// ---- the PS/2 controller (i8042): a laptop's keyboard, often its touchpad ----
//
// Polled from the timer interrupt: each byte goes into a ring with bit 8 set if it came from the
// mouse port. input.st turns them into events (scan code set 1: the controller translates).

static volatile uint16_t ps2[512];
static volatile uint32_t ps2_head, ps2_tail;
static bool has_ps2;

static void ps2_poll(void) {
    if (!has_ps2) return;
    for (int n = 0; n < 32; n++) {
        uint8_t s = inb(0x64);
        if (!(s & 1)) break;
        uint8_t b = inb(0x60);
        uint32_t next = (ps2_head + 1) % 512;
        if (next != ps2_tail) ps2[ps2_head] = (uint16_t)(b | (s & 0x20 ? 0x100 : 0)), ps2_head = next;
    }
}

// The next byte from the PS/2 controller (bit 8: from the mouse), or -1.
int64_t st_k_ps2_read(void) {
    if (ps2_head == ps2_tail) return -1;
    uint16_t v = ps2[ps2_tail];
    ps2_tail = (ps2_tail + 1) % 512;
    return v;
}

static bool ps2_wait_write(void) {
    for (int i = 0; i < 100000; i++) if (!(inb(0x64) & 2)) return true;
    return false;
}
static void ps2_cmd(uint8_t c) { if (ps2_wait_write()) outb(0x64, c); }
static void ps2_data(uint8_t d) { if (ps2_wait_write()) outb(0x60, d); }
static int ps2_reply(void) {
    for (int i = 0; i < 200000; i++) if (inb(0x64) & 1) return inb(0x60);
    return -1;
}

static void ps2_init(void) {
    if (inb(0x64) == 0xff) return; // no controller (some newer laptops)
    has_ps2 = true;
    ps2_cmd(0xad); // keyboard port off
    ps2_cmd(0xa7); // mouse port off
    for (int i = 0; i < 64 && (inb(0x64) & 1); i++) inb(0x60);
    ps2_cmd(0x20);
    int cfg = ps2_reply();
    if (cfg < 0) cfg = 0x40;
    cfg &= ~0x03; // no interrupts (polled)
    cfg |= 0x40;  // translate to scan code set 1
    ps2_cmd(0x60);
    ps2_data((uint8_t)cfg);
    ps2_cmd(0xae); // keyboard on
    ps2_cmd(0xa8); // mouse on
    ps2_cmd(0xd4); // to the mouse: set defaults, then report
    ps2_data(0xf6);
    ps2_reply();
    ps2_cmd(0xd4);
    ps2_data(0xf4);
    ps2_reply();
}

// ---- the screen, for panics ----

static bool fb_panic(const char *msg) {
    if (!boot.fb) return false;
    st_g_target((int64_t)boot.fb, (int64_t)boot.fb_stride, (int64_t)boot.fb_height);
    st_g_fill(0, 0, (int64_t)boot.fb_width, 24 * 6, 0x8b0000);
    int64_t y = 8;
    const char *p = msg;
    while (*p) {
        char line[160];
        int n = 0;
        while (*p && *p != '\n' && n < 159) line[n++] = *p++;
        line[n] = 0;
        if (*p == '\n') p++;
        st_g_text(12, y, line, 0xffffff, 0);
        y += 22;
    }
    return true;
}

// ---- CPU tables: GDT, IDT ----

static uint64_t gdt[3] = {0, 0x00af9a000000ffffull /* 64-bit code */, 0x00cf92000000ffffull /* data */};
static struct { uint16_t off0, sel; uint8_t ist, type; uint16_t off1; uint32_t off2, zero; } idt[256];

// Every vector pushes its number (and a 0 where the CPU pushes no error code), then isr_common saves
// the registers a C call may clobber and the SSE state, and calls st_isr(vector, error, frame).
#define ISR_NOERR(n) "isr" #n ": push $0\n push $" #n "\n jmp isr_common\n"
#define ISR_ERR(n) "isr" #n ": push $" #n "\n jmp isr_common\n"
__asm__(".text\n"
        ISR_NOERR(0) ISR_NOERR(1) ISR_NOERR(2) ISR_NOERR(3) ISR_NOERR(4) ISR_NOERR(5) ISR_NOERR(6) ISR_NOERR(7)
        ISR_ERR(8) ISR_NOERR(9) ISR_ERR(10) ISR_ERR(11) ISR_ERR(12) ISR_ERR(13) ISR_ERR(14) ISR_NOERR(15)
        ISR_NOERR(16) ISR_ERR(17) ISR_NOERR(18) ISR_NOERR(19) ISR_NOERR(20) ISR_ERR(21)
        ISR_NOERR(32) ISR_NOERR(39) ISR_NOERR(255)
        "isr_common:\n"
        "  push %rbp\n push %rax\n push %rcx\n push %rdx\n push %rsi\n push %rdi\n push %r8\n push %r9\n push %r10\n push %r11\n"
        "  mov %rsp, %rbp\n"
        "  sub $512, %rsp\n and $-16, %rsp\n fxsave (%rsp)\n"
        "  mov 80(%rbp), %rdi\n mov 88(%rbp), %rsi\n lea 96(%rbp), %rdx\n"
        "  call st_isr\n"
        "  fxrstor (%rsp)\n mov %rbp, %rsp\n"
        "  pop %r11\n pop %r10\n pop %r9\n pop %r8\n pop %rdi\n pop %rsi\n pop %rdx\n pop %rcx\n pop %rax\n pop %rbp\n"
        "  add $16, %rsp\n"
        "  iretq\n");
extern char isr0[], isr1[], isr2[], isr3[], isr4[], isr5[], isr6[], isr7[], isr8[], isr9[], isr10[], isr11[],
    isr12[], isr13[], isr14[], isr15[], isr16[], isr17[], isr18[], isr19[], isr20[], isr21[], isr32[], isr39[], isr255[];

static void idt_set(int v, void *f) {
    uint64_t a = (uint64_t)f;
    idt[v].off0 = (uint16_t)a, idt[v].sel = 8, idt[v].ist = 0, idt[v].type = 0x8e;
    idt[v].off1 = (uint16_t)(a >> 16), idt[v].off2 = (uint32_t)(a >> 32), idt[v].zero = 0;
}

static void tables_init(void) {
    struct __attribute__((packed)) { uint16_t lim; uint64_t base; } g = {sizeof gdt - 1, (uint64_t)gdt}, i = {sizeof idt - 1, (uint64_t)idt};
    __asm__ volatile("lgdt %0\n"
                     "mov $16, %%ax\n mov %%ax, %%ds\n mov %%ax, %%es\n mov %%ax, %%ss\n mov %%ax, %%fs\n mov %%ax, %%gs\n"
                     "lea 1f(%%rip), %%rax\n push $8\n push %%rax\n lretq\n1:\n" ::"m"(g) : "rax", "memory");
    void *v[] = {isr0, isr1, isr2, isr3, isr4, isr5, isr6, isr7, isr8, isr9, isr10, isr11, isr12, isr13, isr14,
                 isr15, isr16, isr17, isr18, isr19, isr20, isr21};
    for (int k = 0; k < 256; k++) idt_set(k, isr255);
    for (int k = 0; k < 22; k++) idt_set(k, v[k]);
    idt_set(32, isr32);
    idt_set(39, isr39);
    __asm__ volatile("lidt %0" ::"m"(i));
}

// ---- page tables: identity, 512 GiB ----
//
// The first 4 GiB in 2 MiB pages, the rest in 1 GiB pages. RAM (by the memory map) is write-back,
// the framebuffer write-combining (PAT entry 1), everything else uncached: device registers.

static uint64_t pml4[512] __attribute__((aligned(4096)));
static uint64_t pdpt[512] __attribute__((aligned(4096)));
static uint64_t pd[4][512] __attribute__((aligned(4096)));

typedef struct { uint32_t type, pad; uint64_t phys, virt, pages, attr; } MemDesc;
#define MAP_AT(i) ((const MemDesc *)(boot.mmap + (i) * boot.mmap_desc))
#define MAP_N (boot.mmap_desc ? boot.mmap_size / boot.mmap_desc : 0)

static bool is_ram(uint32_t t) { return t >= 1 && t <= 10 && t != 0; } // loader..ACPI NVS: real memory
static bool ram_overlaps(uint64_t a, uint64_t n) {
    for (uint64_t i = 0; i < MAP_N; i++) {
        const MemDesc *d = MAP_AT(i);
        if (is_ram(d->type) && d->phys < a + n && a < d->phys + d->pages * 4096) return true;
    }
    return false;
}

#define P 1ull
#define RW 2ull
#define PWT 8ull
#define PCD 16ull
#define PS 128ull

static void paging_init(void) {
    uint32_t r[4];
    cpuid(0x80000001, r);
    bool gig = r[3] & (1u << 26);
    // PAT: entry 1 (PWT) becomes write-combining; 0 stays write-back, 3 (PCD|PWT) uncached
    wrmsr(0x277, (rdmsr(0x277) & ~0xff00ull) | 0x0100ull);
    pml4[0] = (uint64_t)pdpt | P | RW;
    for (uint64_t g = 0; g < 512; g++) {
        uint64_t a = g << 30;
        if (g < 4 || !gig) {
            if (g >= 4) { pdpt[g] = 0; continue; } // no 1 GiB pages: only the first 4 GiB
            pdpt[g] = (uint64_t)pd[g] | P | RW;
            for (uint64_t k = 0; k < 512; k++) {
                uint64_t b = a + (k << 21);
                uint64_t attr = ram_overlaps(b, 1 << 21) ? 0 : PCD | PWT;
                if (boot.fb && b < boot.fb + boot.fb_stride * boot.fb_height * 4 && boot.fb < b + (1 << 21)) attr = PWT;
                pd[g][k] = b | P | RW | PS | attr;
            }
        } else {
            uint64_t attr = ram_overlaps(a, 1ull << 30) ? 0 : PCD | PWT;
            // a framebuffer up here (a discrete GPU's): write-combining for the whole GiB
            // ponytail: other devices in the same GiB get WC too; split into 2 MiB pages if one does
            if (boot.fb && boot.fb >> 30 == g) attr = PWT;
            pdpt[g] = a | P | RW | PS | attr;
        }
    }
    __asm__ volatile("mov %0, %%cr3" ::"r"(pml4) : "memory");
}

// ---- the local APIC: the timer ----

static uint64_t apic_base;
static bool x2apic;

static uint32_t apic_read(uint32_t reg) { return x2apic ? (uint32_t)rdmsr(0x800 + (reg >> 4)) : REG32(apic_base + reg); }
static void apic_write(uint32_t reg, uint32_t v) {
    if (x2apic) wrmsr(0x800 + (reg >> 4), v);
    else REG32(apic_base + reg) = v;
}

static void apic_init(void) {
    // the old 8259 PICs: all quiet
    outb(0x21, 0xff);
    outb(0xa1, 0xff);
    uint64_t b = rdmsr(0x1b);
    x2apic = b & (1u << 10);
    apic_base = b & 0xffffff000ull;
    wrmsr(0x1b, b | (1u << 11)); // enabled
    apic_write(0xf0, 0x100 | 39); // on; spurious interrupts to vector 39
    apic_write(0x3e0, 0x3);       // timer: divide by 16
    // count how far the timer gets in 10 ms of the TSC
    apic_write(0x320, 1u << 16); // masked, one-shot
    apic_write(0x380, 0xffffffff);
    uint64_t until = rdtime() + timebase / 100;
    while (rdtime() < until) {}
    uint32_t per10ms = 0xffffffff - apic_read(0x390);
    apic_write(0x320, 32 | (1u << 17)); // vector 32, periodic
    apic_write(0x380, per10ms / 10 ? per10ms / 10 : 1000);
}

// ---- interrupts and exceptions ----

static volatile uint64_t irq_counts[256];

static const char *exc_name(uint64_t v) {
    static const char *n[] = {"division by zero", "debug", "NMI", "breakpoint", "overflow", "bound range",
                              "invalid opcode", "no FPU", "double fault", "", "invalid TSS", "segment not present",
                              "stack fault", "general protection fault", "page fault", "", "x87 error",
                              "alignment check", "machine check", "SIMD error", "virtualization", "control protection"};
    return v < 22 && n[v][0] ? n[v] : "exception";
}

void st_isr(uint64_t vec, uint64_t err, uint64_t *frame) {
    irq_counts[vec & 255]++;
    if (vec == 32) {
        ticks++;
        serial_poll();
        ps2_poll();
        apic_write(0xb0, 0);
        return;
    }
    if (vec >= 32) return; // spurious
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    char m[256];
    snprintf(m, sizeof m, "*** kernel panic: %s (vector %llu, error 0x%llx)\n    at pc 0x%llx (kernel at 0x%llx), address 0x%llx\n",
             exc_name(vec), (unsigned long long)vec, (unsigned long long)err, (unsigned long long)frame[0],
             (unsigned long long)boot.kernel, (unsigned long long)cr2);
    kputs(m, strlen(m));
    fb_panic(m);
    kexit(101);
}

int64_t st_k_irqs(int64_t which) { return which == 5 ? (int64_t)irq_counts[32] : which >= 0 && which < 256 ? (int64_t)irq_counts[which] : 0; }
// Device interrupts: on x86 the drivers poll (the PS/2 ring, xHCI's event ring).
void st_k_irq_enable(int64_t irq) { (void)irq; }
int64_t st_k_irq_count(int64_t irq) { (void)irq; return 0; }

// ---- memory ----

static void gc_roots(void) {
    uint64_t regs[6];
    __asm__ volatile("mov %%rbx, 0(%0)\n mov %%rbp, 8(%0)\n mov %%r12, 16(%0)\n mov %%r13, 24(%0)\n mov %%r14, 32(%0)\n mov %%r15, 40(%0)" ::"r"(regs)
                     : "memory");
    gc_scan((uintptr_t)&__data_start, (uintptr_t)&__bss_end);
    gc_scan((uintptr_t)regs, (uintptr_t)&__stack_top);
    gc_runs++;
}

int64_t st_k_kernel_size(void) { return (int64_t)boot.kernel_size; }

// The heap: the largest block of free RAM (conventional memory, by the firmware's map).
static void heap_init(void) {
    uint64_t best = 0, best_n = 0, total = 0;
    for (uint64_t i = 0; i < MAP_N; i++) {
        const MemDesc *d = MAP_AT(i);
        if (d->type == 7) {
            total += d->pages * 4096;
            if (d->pages * 4096 > best_n && d->phys >= (1 << 20)) best = d->phys, best_n = d->pages * 4096;
        }
    }
    heap_next = heap_start = best;
    heap_end = best + best_n;
    ram_size = total;
}

// Random bits from the CPU (RDRAND), or -1 if it has none.
int64_t st_k_hw_random(void) {
    uint32_t r[4];
    cpuid(1, r);
    if (!(r[2] & (1u << 30))) return -1;
    for (int i = 0; i < 10; i++) {
        uint64_t v;
        uint8_t ok;
        __asm__ volatile("rdrand %0; setc %1" : "=r"(v), "=qm"(ok));
        if (ok) return (int64_t)(v & 0x7fffffffffffffffull);
    }
    return -1;
}

// The screen the firmware set up: what display.st needs to draw on it.
int64_t st_k_fb(int64_t what) {
    switch (what) {
    case 0: return (int64_t)boot.fb;
    case 1: return (int64_t)boot.fb_width;
    case 2: return (int64_t)boot.fb_height;
    case 3: return (int64_t)boot.fb_stride;
    default: return (int64_t)boot.fb_format;
    }
}

// ---- programs: an RV64IMD interpreter ----
//
// The frame (as on RISC-V): 0 pc, 8*i x1..x31, 256+8*i f0..f31, 512 fcsr, 520 satp, 528 scause,
// 536 stval. Addresses go through the Sv39 page table at satp, and only user pages (U) count, so a
// program sees exactly the memory proc.st gave it.

#define RV_FAULT(c, a) do { cause = (c); tval = (a); goto trap; } while (0)

static uint8_t *rv_addr(uint64_t root, uint64_t va, uint64_t need) { // need: R 2, W 4, X 8
    if ((int64_t)va << 25 >> 25 != (int64_t)va) return NULL;
    uint64_t t = root;
    for (int lvl = 2; lvl >= 0; lvl--) {
        uint64_t pte = ((uint64_t *)t)[(va >> (12 + 9 * lvl)) & 511];
        if (!(pte & 1)) return NULL;
        if (pte & 0xe) { // a leaf
            if (!(pte & 16) || !(pte & need)) return NULL;
            uint64_t size = 1ull << (12 + 9 * lvl);
            return (uint8_t *)(((pte >> 10) << 12) + (va & (size - 1)));
        }
        t = (pte >> 10) << 12;
    }
    return NULL;
}

static double nearbyint_even(double p) { // round half to even
    double f = floor(p), d = p - f;
    if (d > 0.5 || (d == 0.5 && fmod(f, 2.0) != 0)) f += 1;
    return f;
}

static int64_t rv_run(uint64_t *f, uint64_t until) {
    uint64_t *x = f, pc = f[0], root = (f[65] & ((1ull << 44) - 1)) << 12;
    double *fr = (double *)(f + 32);
    uint64_t cause = 0, tval = 0;
    uint64_t page_va = ~0ull;
    uint8_t *page = NULL;
    for (uint64_t n = 0;; n++) {
        if ((n & 4095) == 0 && rdtime() >= until) { f[0] = pc; return -1; }
        if ((pc >> 12) != page_va) {
            page = rv_addr(root, pc & ~4095ull, 8);
            if (!page) RV_FAULT(12, pc);
            page_va = pc >> 12;
        }
        if (pc & 3) RV_FAULT(0, pc);
        uint32_t in = *(uint32_t *)(page + (pc & 4095));
        uint32_t op = in & 0x7f, rd = (in >> 7) & 31, f3 = (in >> 12) & 7, rs1 = (in >> 15) & 31, rs2 = (in >> 20) & 31, f7 = in >> 25;
        int64_t imm_i = (int32_t)in >> 20;
        int64_t imm_s = ((int32_t)in >> 25 << 5) | ((in >> 7) & 31);
        int64_t imm_b = ((int64_t)((int32_t)in >> 31) << 12) | ((in >> 7 & 1) << 11) | ((in >> 25 & 63) << 5) | ((in >> 8 & 15) << 1);
        int64_t imm_u = (int64_t)(int32_t)(in & 0xfffff000);
        int64_t imm_j = ((int64_t)((int32_t)in >> 31) << 20) | (in & 0xff000) | ((in >> 20 & 1) << 11) | ((in >> 21 & 1023) << 1);
        uint64_t a = rs1 ? x[rs1] : 0, b = rs2 ? x[rs2] : 0, r = 0, next = pc + 4;
        bool wr = true;
        switch (op) {
        case 0x37: r = (uint64_t)imm_u; break;
        case 0x17: r = pc + (uint64_t)imm_u; break;
        case 0x6f: r = pc + 4; next = pc + (uint64_t)imm_j; break;
        case 0x67: r = pc + 4; next = (a + (uint64_t)imm_i) & ~1ull; break;
        case 0x63: {
            bool t;
            switch (f3) {
            case 0: t = a == b; break;
            case 1: t = a != b; break;
            case 4: t = (int64_t)a < (int64_t)b; break;
            case 5: t = (int64_t)a >= (int64_t)b; break;
            case 6: t = a < b; break;
            case 7: t = a >= b; break;
            default: RV_FAULT(2, in);
            }
            if (t) next = pc + (uint64_t)imm_b;
            wr = false;
            break;
        }
        case 0x03:
        case 0x07: { // loads (0x07: fld)
            uint64_t va = a + (uint64_t)imm_i;
            int size = 1 << (f3 & 3);
            if ((va & 4095) + (uint64_t)size > 4096 && (va & (uint64_t)(size - 1))) RV_FAULT(4, va);
            uint8_t *p = rv_addr(root, va, 2);
            if (!p) RV_FAULT(13, va);
            if (op == 0x07) {
                if (f3 != 3) RV_FAULT(2, in);
                memcpy(&fr[rd], p, 8);
                wr = false;
                break;
            }
            switch (f3) {
            case 0: r = (uint64_t)(int64_t)*(int8_t *)p; break;
            case 1: { int16_t v; memcpy(&v, p, 2); r = (uint64_t)(int64_t)v; break; }
            case 2: { int32_t v; memcpy(&v, p, 4); r = (uint64_t)(int64_t)v; break; }
            case 3: memcpy(&r, p, 8); break;
            case 4: r = *p; break;
            case 5: { uint16_t v; memcpy(&v, p, 2); r = v; break; }
            case 6: { uint32_t v; memcpy(&v, p, 4); r = v; break; }
            default: RV_FAULT(2, in);
            }
            break;
        }
        case 0x23:
        case 0x27: { // stores (0x27: fsd)
            uint64_t va = a + (uint64_t)imm_s;
            int size = 1 << (f3 & 3);
            if ((va & 4095) + (uint64_t)size > 4096 && (va & (uint64_t)(size - 1))) RV_FAULT(6, va);
            uint8_t *p = rv_addr(root, va, 4);
            if (!p) RV_FAULT(15, va);
            if (op == 0x27) memcpy(p, &fr[rs2], 8);
            else memcpy(p, &b, (size_t)size);
            wr = false;
            break;
        }
        case 0x13:
        case 0x1b:
        case 0x33:
        case 0x3b: {
            bool w = op == 0x1b || op == 0x3b, reg = op == 0x33 || op == 0x3b;
            uint64_t v = reg ? b : (uint64_t)imm_i;
            if (reg && f7 == 1) { // M
                if (w) {
                    int32_t p = (int32_t)a, q = (int32_t)v;
                    uint32_t up = (uint32_t)a, uq = (uint32_t)v;
                    switch (f3) {
                    case 0: r = (uint64_t)(int64_t)(int32_t)(up * uq); break;
                    case 4: r = (uint64_t)(int64_t)(q == 0 ? -1 : (p == INT32_MIN && q == -1) ? p : p / q); break;
                    case 5: r = (uint64_t)(int64_t)(int32_t)(uq == 0 ? ~0u : up / uq); break;
                    case 6: r = (uint64_t)(int64_t)(q == 0 ? p : (p == INT32_MIN && q == -1) ? 0 : p % q); break;
                    case 7: r = (uint64_t)(int64_t)(int32_t)(uq == 0 ? up : up % uq); break;
                    default: RV_FAULT(2, in);
                    }
                } else {
                    int64_t p = (int64_t)a, q = (int64_t)v;
                    switch (f3) {
                    case 0: r = a * v; break;
                    case 1: r = (uint64_t)(((__int128)p * q) >> 64); break;
                    case 2: r = (uint64_t)(((__int128)p * (unsigned __int128)v) >> 64); break;
                    case 3: r = (uint64_t)(((unsigned __int128)a * v) >> 64); break;
                    case 4: r = (uint64_t)(q == 0 ? -1 : (p == INT64_MIN && q == -1) ? p : p / q); break;
                    case 5: r = v == 0 ? ~0ull : a / v; break;
                    case 6: r = (uint64_t)(q == 0 ? p : (p == INT64_MIN && q == -1) ? 0 : p % q); break;
                    case 7: r = v == 0 ? a : a % v; break;
                    }
                }
                break;
            }
            unsigned sh = (unsigned)(v & (w ? 31 : 63));
            bool alt = reg ? f7 == 0x20 : (f3 == 5 && (in >> 30 & 1));
            switch (f3) {
            case 0: r = reg && alt ? a - v : a + v; break;
            case 1: r = a << sh; break;
            case 2: r = (int64_t)a < (int64_t)v; break;
            case 3: r = a < v; break;
            case 4: r = a ^ v; break;
            case 5: r = w ? (alt ? (uint64_t)((int32_t)a >> sh) : (uint64_t)((uint32_t)a >> sh)) : (alt ? (uint64_t)((int64_t)a >> sh) : a >> sh); break;
            case 6: r = a | v; break;
            case 7: r = a & v; break;
            }
            if (w) r = (uint64_t)(int64_t)(int32_t)r;
            break;
        }
        case 0x0f: wr = false; break; // fence
        case 0x73:
            if (in == 0x73) { cause = 8; tval = 0; goto trap; }        // ecall
            if (in == 0x100073) { cause = 3; tval = pc; goto trap; }   // ebreak
            RV_FAULT(2, in);
        case 0x53: { // D: the operations cc.st uses
            double p = fr[rs1], q = fr[rs2], d = 0;
            bool to_f = true;
            switch (f7) {
            case 0x01: d = p + q; break;
            case 0x05: d = p - q; break;
            case 0x09: d = p * q; break;
            case 0x0d: d = p / q; break;
            case 0x2d: d = sqrt(p); break;
            case 0x11: {
                uint64_t ub, uq;
                memcpy(&ub, &p, 8);
                memcpy(&uq, &q, 8);
                uint64_t s = f3 == 0 ? uq : f3 == 1 ? ~uq : (ub ^ uq);
                ub = (ub & ~(1ull << 63)) | (s & (1ull << 63));
                memcpy(&d, &ub, 8);
                break;
            }
            case 0x51: r = f3 == 2 ? p == q : f3 == 1 ? p < q : p <= q; to_f = false; break;
            case 0x61: { // fcvt.l.d with a rounding mode
                double t = f3 == 1 ? trunc(p) : f3 == 2 ? floor(p) : f3 == 3 ? ceil(p) : f3 == 4 ? round(p) : nearbyint_even(p);
                r = p != p ? (uint64_t)INT64_MAX : t >= 9.2233720368547758e18 ? (uint64_t)INT64_MAX : t < -9.2233720368547758e18 ? (uint64_t)INT64_MIN : (uint64_t)(int64_t)t;
                to_f = false;
                break;
            }
            case 0x69: d = (double)(int64_t)a; break;
            case 0x71: memcpy(&r, &p, 8); to_f = false; break;  // fmv.x.d
            case 0x79: memcpy(&d, &a, 8); break;                // fmv.d.x
            default: RV_FAULT(2, in);
            }
            if (to_f) { fr[rd] = d; wr = false; }
            break;
        }
        default: RV_FAULT(2, in);
        }
        if (wr && rd) x[rd] = r;
        pc = next;
    }
trap:
    f[0] = pc;
    f[66] = cause;
    f[67] = tval;
    return (int64_t)cause;
}

// Run a process (its frame) for up to `ms` milliseconds. Returns the cause when it traps (8: a
// system call; a fault), -1 when its time is up.
int64_t st_k_user_run(int64_t frame, int64_t ms) {
    return rv_run((uint64_t *)frame, rdtime() + (uint64_t)ms * (timebase / 1000));
}

// ---- start ----

int main(void);

void kmain(BootInfo *bi) {
    boot = *bi;
    timebase = boot.tsc_hz ? boot.tsc_hz : 2000000000ull;
    tables_init();
    paging_init();
    heap_init();
    serial_init();
    read_clock();
    apic_init();
    ps2_init();
    __asm__ volatile("sti");
    kexit(main());
}
