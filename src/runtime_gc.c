// stellang's own garbage collector, for the targets without Boehm GC: the browser
// (runtime_web.c) and bare metal (runtime_kernel.c). Appended after runtime.c.
//
// Mark and sweep over 64 KiB pages. Small objects live in pages of one size class (a header with
// mark/alloc bitmaps, then the slots); big ones get whole pages. Pointers are found conservatively
// (any word that points into a live object).

#define PAGE 65536u
#define HDR 2048u
#define NPAGES 65536u // 4 GiB / 64 KiB

typedef struct Page {
    uint32_t size;   // slot size (small) or object size (large)
    uint32_t nobj;   // slots in the page (1 for large objects)
    uint32_t npages; // pages in a large object's span
    uint32_t atomic; // the slots hold no pointers
    struct Page *next;
    uint8_t mark[1000], used[1000];
} Page;

static const uint32_t CLASSES[] = {8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 21760, 31744};
#define NCLASS (sizeof CLASSES / sizeof CLASSES[0])

static Page **ptab;                   // page index -> its header (also for the inner pages of large spans)
static Page *pages;                   // every page/span in use
static Page *free_spans;              // large spans swept free, for reuse
static void *free_list[NCLASS][2];    // per size class and atomic-ness
static size_t since_gc, live_bytes;   // bytes allocated since the last collection / surviving it
static uintptr_t heap_lo = UINTPTR_MAX, heap_hi;

// Each platform supplies these: fresh zeroed PAGE-aligned pages, and the roots to scan
// (gc_scan each range of memory that may hold pointers; the gc_stack is drained afterwards).
static void *gc_grow(uint32_t n);
static void gc_roots(void);
static void gc_scan(uintptr_t from, uintptr_t to);
#ifdef GC_AUTO
static void gc_maybe(void); // collect now if it's time (bare metal can scan its own stack)
#endif

void GC_init(void) {
    if (!ptab) ptab = gc_grow(NPAGES * sizeof(Page *) / PAGE);
}

static void gc_track(Page *p, uint32_t npages) {
    uintptr_t a = (uintptr_t)p;
    for (uint32_t i = 0; i < npages; i++) ptab[(a >> 16) + i] = p;
    p->next = pages;
    pages = p;
    if (a < heap_lo) heap_lo = a;
    if (a + npages * PAGE > heap_hi) heap_hi = a + npages * PAGE;
}

static void *gc_alloc_large(size_t n, int atomic) {
    uint32_t np = (uint32_t)((n + HDR + PAGE - 1) / PAGE);
    Page *p = NULL;
    for (Page **q = &free_spans; *q; q = &(*q)->next) {
        if ((*q)->npages == np) {
            p = *q;
            *q = p->next;
            break;
        }
    }
    if (p) {
        memset((char *)p + HDR, 0, (size_t)np * PAGE - HDR);
    } else {
        p = gc_grow(np);
    }
    p->size = (uint32_t)n;
    p->nobj = 1;
    p->npages = np;
    p->atomic = (uint32_t)atomic;
    memset(p->mark, 0, sizeof p->mark);
    memset(p->used, 0, sizeof p->used);
    p->used[0] = 1;
    gc_track(p, np);
    since_gc += n;
    return (char *)p + HDR;
}

static void *gc_alloc(size_t n, int atomic) {
    if (!ptab) GC_init();
#ifdef GC_AUTO
    gc_maybe();
#endif
    if (n == 0) n = 1;
    if (n > CLASSES[NCLASS - 1]) return gc_alloc_large(n, atomic);
    unsigned c = 0;
    while (CLASSES[c] < n) c++;
    void **fl = &free_list[c][atomic];
    if (!*fl) {
        Page *p = gc_grow(1);
        p->size = CLASSES[c];
        p->nobj = (PAGE - HDR) / CLASSES[c];
        p->npages = 1;
        p->atomic = (uint32_t)atomic;
        gc_track(p, 1);
        char *base = (char *)p + HDR;
        for (uint32_t i = p->nobj; i-- > 0;) {
            *(void **)(base + i * p->size) = *fl;
            *fl = base + i * p->size;
        }
    }
    char *o = *fl;
    *fl = *(void **)o;
    Page *p = ptab[(uintptr_t)o >> 16];
    uint32_t i = (uint32_t)((o - ((char *)p + HDR)) / p->size);
    p->used[i >> 3] |= (uint8_t)(1 << (i & 7));
    memset(o, 0, p->size);
    since_gc += p->size;
    return o;
}

void *GC_malloc(size_t n) { return gc_alloc(n, 0); }
void *GC_malloc_atomic(size_t n) { return gc_alloc(n, 1); }

void *GC_realloc(void *old, size_t n) {
    if (!old) return gc_alloc(n, 0);
    Page *p = ptab[(uintptr_t)old >> 16];
    if (n <= p->size) return old;
    void *r = gc_alloc(n, (int)p->atomic);
    memcpy(r, old, p->size);
    return r;
}

static uintptr_t *gc_stack;
static size_t gc_nstack, gc_capstack;

static void gc_mark(uintptr_t a) {
    if (a < heap_lo || a >= heap_hi) return;
    Page *p = ptab[a >> 16];
    if (!p) return;
    uintptr_t base = (uintptr_t)p + HDR;
    if (a < base) return;
    uint32_t i = (uint32_t)((a - base) / p->size);
    if (i >= p->nobj || !(p->used[i >> 3] & (1 << (i & 7))) || (p->mark[i >> 3] & (1 << (i & 7)))) return;
    p->mark[i >> 3] |= (uint8_t)(1 << (i & 7));
    if (p->atomic) return;
    if (gc_nstack == gc_capstack) { // (pages of our own: libc's malloc must not share memory.grow with us)
        size_t cap = gc_capstack ? gc_capstack * 2 : PAGE / sizeof *gc_stack;
        uintptr_t *s = gc_grow((uint32_t)(cap * sizeof *gc_stack / PAGE));
        if (gc_nstack) memcpy(s, gc_stack, gc_nstack * sizeof *gc_stack);
        gc_stack = s;
        gc_capstack = cap;
    }
    gc_stack[gc_nstack++] = base + (uintptr_t)i * p->size;
}

static void gc_scan(uintptr_t from, uintptr_t to) {
    const uintptr_t w = sizeof(uintptr_t);
    for (from = (from + w - 1) & ~(w - 1); from + w <= to; from += w) gc_mark(*(uintptr_t *)from);
}

static void gc_collect(void) {
    gc_roots();
    while (gc_nstack) {
        uintptr_t o = gc_stack[--gc_nstack];
        Page *p = ptab[o >> 16];
        gc_scan(o, o + p->size);
    }
    memset(free_list, 0, sizeof free_list);
    live_bytes = 0;
    Page **q = &pages;
    while (*q) {
        Page *p = *q;
        if (p->nobj == 1 && p->npages > 0 && p->size > CLASSES[NCLASS - 1]) {
            if (!(p->mark[0] & 1)) { // a dead large object: its span goes back for reuse
                *q = p->next;
                uintptr_t a = (uintptr_t)p;
                for (uint32_t i = 0; i < p->npages; i++) ptab[(a >> 16) + i] = NULL;
                p->next = free_spans;
                free_spans = p;
                continue;
            }
            p->mark[0] = 0;
            live_bytes += p->size;
            q = &p->next;
            continue;
        }
        unsigned c = 0;
        while (CLASSES[c] != p->size) c++;
        char *base = (char *)p + HDR;
        for (uint32_t i = p->nobj; i-- > 0;) {
            uint8_t bit = (uint8_t)(1 << (i & 7));
            if (p->mark[i >> 3] & bit) {
                live_bytes += p->size;
                continue;
            }
            p->used[i >> 3] &= (uint8_t)~bit;
            *(void **)(base + i * p->size) = free_list[c][p->atomic];
            free_list[c][p->atomic] = base + i * p->size;
        }
        memset(p->mark, 0, sizeof p->mark);
        q = &p->next;
    }
    since_gc = 0;
}

