// The UEFI loader for an x86_64 StellaOS kernel (`stellang --kernel --arch x86_64` → os.efi).
//
// Built as a UEFI application (PE, Microsoft ABI) with the kernel's ELF inside it (kernel_elf, from an
// .incbin). It asks the firmware for what only the firmware knows (the screen, the memory map, the
// clock rate, the runtime services), leaves boot services, puts the kernel at some free address,
// applies its relocations (it is position-independent) and jumps to it with a BootInfo.
// Nothing here touches a disk: the kernel came in with this file.

typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef u64 usize;
typedef u64 Status;
typedef void *Handle;
#define EFIAPI __attribute__((ms_abi))
#define ERR(s) ((s) >> 63)

typedef struct { u32 a; u16 b, c; u8 d[8]; } Guid;

typedef struct {
    u64 sig;
    u32 rev, size, crc, rsvd;
} TableHeader;

typedef struct Out {
    void *reset;
    Status(EFIAPI *output)(struct Out *, const u16 *);
} TextOut;

typedef struct {
    u32 type, pad;
    u64 phys, virt, pages, attr;
} MemDesc;

typedef struct {
    TableHeader hdr;
    void *raise_tpl, *restore_tpl;
    Status(EFIAPI *alloc_pages)(int type, int memtype, usize pages, u64 *addr);
    void *free_pages;
    Status(EFIAPI *get_memory_map)(usize *size, MemDesc *map, usize *key, usize *desc_size, u32 *ver);
    Status(EFIAPI *alloc_pool)(int memtype, usize size, void **out);
    void *free_pool, *create_event, *set_timer, *wait_for_event, *signal_event, *close_event, *check_event;
    void *install_proto, *reinstall_proto, *uninstall_proto, *handle_proto, *rsvd, *register_notify;
    void *locate_handle, *locate_device_path, *install_config;
    void *load_image, *start_image, *exit;
    void *unload_image;
    Status(EFIAPI *exit_boot_services)(Handle, usize key);
    void *get_next_count;
    Status(EFIAPI *stall)(usize us);
    Status(EFIAPI *set_watchdog)(usize timeout, u64 code, usize size, void *data);
    void *connect, *disconnect, *open_proto, *close_proto, *open_proto_info, *protos_per_handle;
    void *locate_handle_buffer;
    Status(EFIAPI *locate_protocol)(const Guid *, void *reg, void **out);
} BootServices;

typedef struct {
    TableHeader hdr;
    u16 *vendor;
    u32 rev;
    Handle con_in_h;
    void *con_in;
    Handle con_out_h;
    TextOut *con_out;
    Handle err_h;
    void *err;
    void *runtime;
    BootServices *boot;
} SystemTable;

typedef struct {
    u32 version, width, height, format;
    u32 masks[4];
    u32 stride; // pixels per scan line
} ModeInfo;

typedef struct {
    u32 max_mode, mode;
    ModeInfo *info;
    usize info_size;
    u64 fb;
    usize fb_size;
} Mode;

typedef struct Gop {
    Status(EFIAPI *query)(struct Gop *, u32 mode, usize *size, ModeInfo **info);
    Status(EFIAPI *set)(struct Gop *, u32 mode);
    void *blt;
    Mode *mode;
} Gop;

// A mode we can draw on: 32-bit pixels, red/green/blue bytes in either order.
static int usable(const ModeInfo *m) {
    if (m->format == 0 || m->format == 1) return 1;
    return m->format == 2 && m->masks[1] == 0xff00 && m->masks[3] == 0xff000000u &&
           ((m->masks[0] == 0xff0000 && m->masks[2] == 0xff) || (m->masks[0] == 0xff && m->masks[2] == 0xff0000));
}

// What the kernel gets (runtime_kernel_x86.c has the same struct).
typedef struct {
    u64 fb, fb_width, fb_height, fb_stride, fb_format; // fb_format: 0 RGBX, 1 BGRX (0x00RRGGBB)
    u64 mmap, mmap_size, mmap_desc;                    // the memory map after ExitBootServices
    u64 runtime;                                       // EFI_RUNTIME_SERVICES *
    u64 tsc_hz;
    u64 kernel, kernel_size;                           // where the kernel landed
} BootInfo;

extern const u8 kernel_elf[];
extern const u8 kernel_elf_end[];
__asm__(".section .rdata,\"dr\"\n.p2align 4\n.globl kernel_elf\nkernel_elf:\n.incbin \"" KERNEL_ELF "\"\n.globl kernel_elf_end\nkernel_elf_end:\n.text\n");

static SystemTable *st;

static void say(const char *s) {
    u16 b[128];
    while (*s) {
        int n = 0;
        while (*s && n < 126) {
            if (*s == '\n') b[n++] = '\r';
            b[n++] = (u8)*s++;
        }
        b[n] = 0;
        st->con_out->output(st->con_out, b);
    }
}

static void fail(const char *s) {
    say("StellaOS: ");
    say(s);
    say("\n");
    for (;;) st->boot->stall(1000000);
}

static void *mset(void *d, int c, usize n) {
    u8 *p = d;
    while (n--) *p++ = (u8)c;
    return d;
}
static void mcpy(void *d, const void *s, usize n) {
    u8 *a = d;
    const u8 *b = s;
    while (n--) *a++ = *b++;
}
// clang may emit calls to these
void *memset(void *d, int c, usize n) { return mset(d, c, n); }
void *memcpy(void *d, const void *s, usize n) { mcpy(d, s, n); return d; }

static u64 rdtsc(void) {
    u32 lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return (u64)hi << 32 | lo;
}

// ELF64
typedef struct {
    u8 ident[16];
    u16 type, machine;
    u32 version;
    u64 entry, phoff, shoff;
    u32 flags;
    u16 ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
} Ehdr;
typedef struct {
    u32 type, flags;
    u64 off, vaddr, paddr, filesz, memsz, align;
} Phdr;
typedef struct { u64 off, info; long long addend; } Rela;

Status EFIAPI efi_main(Handle image, SystemTable *table) {
    st = table;
    BootServices *bs = st->boot;
    bs->set_watchdog(0, 0, 0, 0); // the firmware would reset the machine after 5 minutes otherwise
    say("StellaOS is starting...\n");

    // the screen
    static const Guid gop_guid = {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}};
    Gop *gop = 0;
    BootInfo bi;
    mset(&bi, 0, sizeof bi);
    if (!ERR(bs->locate_protocol(&gop_guid, 0, (void **)&gop)) && gop && gop->mode && gop->mode->info) {
        // laptops start in the panel's own resolution; only a small mode (800x600 from a boot menu)
        // is swapped for the biggest one up to 4K
        if (gop->mode->info->width < 1024 || !usable(gop->mode->info)) {
            u32 best = gop->mode->mode;
            u64 best_px = 0;
            for (u32 i = 0; i < gop->mode->max_mode; i++) {
                ModeInfo *m = 0;
                usize sz = 0;
                if (ERR(gop->query(gop, i, &sz, &m)) || !m || !usable(m) || m->width > 3840) continue;
                if ((u64)m->width * m->height > best_px) best = i, best_px = (u64)m->width * m->height;
            }
            if (best_px && best != gop->mode->mode) gop->set(gop, best);
        }
        ModeInfo *m = gop->mode->info;
        if (usable(m) && gop->mode->fb) {
            bi.fb = gop->mode->fb;
            bi.fb_width = m->width;
            bi.fb_height = m->height;
            bi.fb_stride = m->stride;
            bi.fb_format = m->format == 2 ? (m->masks[0] == 0xff ? 0 : 1) : m->format;
        } else {
            say("(the screen's pixels are in a format StellaOS can't draw: no desktop)\n");
        }
    } else {
        say("(no graphics output: the desktop won't come up)\n");
    }

    // the kernel: lay out its segments at a fresh address, then relocate
    const Ehdr *eh = (const Ehdr *)kernel_elf;
    if (eh->ident[0] != 0x7f || eh->ident[1] != 'E' || eh->machine != 62) fail("the kernel inside is not an x86_64 ELF");
    const Phdr *ph = (const Phdr *)(kernel_elf + eh->phoff);
    u64 top = 0;
    const Phdr *dyn = 0;
    for (int i = 0; i < eh->phnum; i++) {
        if (ph[i].type == 1 && ph[i].vaddr + ph[i].memsz > top) top = ph[i].vaddr + ph[i].memsz;
        if (ph[i].type == 2) dyn = &ph[i];
    }
    top = (top + 0xffff) & ~0xffffull;
    u64 base = 0;
    if (ERR(bs->alloc_pages(0 /* any */, 2 /* loader data */, top / 4096, &base))) fail("no memory for the kernel");
    mset((void *)base, 0, top);
    for (int i = 0; i < eh->phnum; i++)
        if (ph[i].type == 1) mcpy((void *)(base + ph[i].vaddr), kernel_elf + ph[i].off, ph[i].filesz);
    if (dyn) {
        const u64 *d = (const u64 *)(kernel_elf + dyn->off);
        u64 rela = 0, relasz = 0;
        for (; d[0]; d += 2) {
            if (d[0] == 7) rela = d[1];   // DT_RELA
            if (d[0] == 8) relasz = d[1]; // DT_RELASZ
        }
        for (const Rela *r = (const Rela *)(base + rela); (u64)r < base + rela + relasz; r++) {
            if ((u32)r->info != 8) fail("the kernel has a relocation other than R_X86_64_RELATIVE");
            *(u64 *)(base + r->off) = base + (u64)r->addend;
        }
    }
    bi.kernel = base;
    bi.kernel_size = top;
    bi.runtime = (u64)st->runtime;

    // the time stamp counter's rate, against the firmware's microsecond stall
    u64 t0 = rdtsc();
    bs->stall(50000);
    bi.tsc_hz = (rdtsc() - t0) * 20;

    // leave boot services: the memory map must be current when we do
    usize size = 0, key = 0, dsize = 0;
    u32 ver = 0;
    MemDesc *map = 0;
    bs->get_memory_map(&size, 0, &key, &dsize, &ver);
    size += 16 * dsize;
    if (ERR(bs->alloc_pool(2, size, (void **)&map))) fail("no memory for the memory map");
    say("leaving the firmware\n");
    for (int tries = 0;; tries++) {
        usize s = size;
        if (ERR(bs->get_memory_map(&s, map, &key, &dsize, &ver))) fail("cannot read the memory map");
        if (!ERR(bs->exit_boot_services(image, key))) {
            bi.mmap_size = s;
            break;
        }
        if (tries > 4) fail("the firmware won't let go (ExitBootServices)");
    }
    bi.mmap = (u64)map;
    bi.mmap_desc = dsize;
    __asm__ volatile("cli");
    typedef void __attribute__((sysv_abi)) Entry(BootInfo *);
    ((Entry *)(base + eh->entry))(&bi);
    for (;;) __asm__ volatile("hlt");
}
