// stellang browser runtime (compiled with runtime.c for `stellang --web`): a garbage collector for
// WebAssembly, and the glue between stellang apps and the page (rendering, events, state, timers,
// fetch). The page side lives in loader.js.
// (appended to runtime.c, whose includes, Vec and st_vec_* it uses)

// ---- garbage collector ----
//
// Mark and sweep over 64 KiB pages taken straight from `memory.grow`. Small objects live in pages of
// one size class (a header with mark/alloc bitmaps, then the slots); big ones get whole pages.
// WebAssembly can't scan its own gc_stack, so collection only happens between calls from JavaScript,
// when no stellang code is running: the only roots are then the globals (the data segment) and what
// they reach. Pointers are found conservatively (any word that points into a live object).

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

extern char __global_base, __data_end; // the data segment, from wasm-ld

static void *gc_grow(uint32_t n) {
    int32_t old = __builtin_wasm_memory_grow(0, n);
    if (old < 0) {
        static const char m[] = "panic: out of memory\n";
        st_panic(m);
    }
    return (void *)((uintptr_t)old * PAGE);
}

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
    for (from = (from + 3) & ~(uintptr_t)3; from + 4 <= to; from += 4) gc_mark(*(uint32_t *)from);
}

static void gc_collect(void) {
    gc_scan((uintptr_t)&__global_base, (uintptr_t)&__data_end);
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

// Called by the loader after each call into stellang returns (nothing on the gc_stack then).
__attribute__((export_name("st_gc"))) void st_gc(int32_t force) {
    size_t limit = live_bytes < (1u << 20) ? (1u << 20) : live_bytes;
    if (force || since_gc > limit) gc_collect();
}

__attribute__((export_name("st_heap_size"))) int32_t st_heap_size(void) { return (int32_t)live_bytes; }

// ---- the page ----

#define JS(name) __attribute__((import_module("env"), import_name(#name)))
JS(js_patch) void js_patch(const char *selector, const char *html);
JS(js_invalidate) void js_invalidate(void);
JS(js_timer) void js_timer(int32_t id, int32_t ms, int32_t repeat);
JS(js_clear_timer) void js_clear_timer(int32_t id);
JS(js_fetch) void js_fetch(int32_t id, const char *method, const char *url, const char *body);
JS(js_storage_get) char *js_storage_get(const char *key);
JS(js_storage_set) void js_storage_set(const char *key, const char *value);
JS(js_location) char *js_location(void);
JS(js_navigate) void js_navigate(const char *path);
JS(js_set_title) void js_set_title(const char *title);
JS(js_element_text) char *js_element_text(const char *id);

typedef void *Closure; // points at { fn, captures... }
#define FN(c) (*(void **)(c))

// A growable table of GC pointers kept alive by a global.
#define AT(t, i) (((void **)(t)->data)[i])
static int64_t table_add(Vec **t, void *x) {
    if (!*t) *t = st_vec_new(0, sizeof(void *), 0);
    if ((*t)->len == (*t)->cap) st_vec_grow(*t, sizeof(void *));
    AT(*t, (*t)->len) = x;
    return (*t)->len++;
}

static Vec *handlers, *arities, *hooks, *timers, *fetches;
static Closure root;
static const char *root_sel;
static int64_t hook_i;
static bool rendering, dirty;

// The app's top component, rendered into `selector` now and after every state change.
void st_mount(const char *selector, Closure app) {
    root_sel = selector;
    root = app;
    extern void st_render(void);
    st_render();
}

__attribute__((export_name("st_render"))) void st_render(void) {
    dirty = false;
    if (!root) return;
    if (handlers) handlers->len = arities->len = 0;
    hook_i = 0;
    rendering = true;
    char *html = ((char *(*)(Closure))FN(root))(root);
    rendering = false;
    js_patch(root_sel, html);
}

// State that survives re-rendering: the i-th `signal()` of a render gets the i-th cell.
void **st_hook(void) {
    if (!rendering) return GC_malloc(sizeof(void *));
    if (!hooks || hook_i == hooks->len) table_add(&hooks, GC_malloc(sizeof(void *)));
    return AT(hooks, hook_i++);
}

// Some state changed: render again (once, before the next frame).
void st_invalidate(void) {
    if (dirty || !root) return;
    dirty = true;
    js_invalidate();
}

// An event handler of the element being rendered; `data-on-click="<id>"` refers to it.
int64_t st_on(Closure f, int64_t arity) {
    table_add(&arities, (void *)(intptr_t)arity);
    return table_add(&handlers, f);
}

__attribute__((export_name("st_dispatch"))) void st_dispatch(int32_t id, const char *value) {
    if (!handlers || id < 0 || id >= handlers->len) return;
    Closure f = AT(handlers, id);
    if ((intptr_t)AT(arities, id) == 1) ((void (*)(Closure, const char *))FN(f))(f, value);
    else ((void (*)(Closure))FN(f))(f);
}

// A string for JavaScript to fill in (it writes `len` bytes; the terminator is already there).
__attribute__((export_name("st_new_str"))) char *st_new_str(int32_t len) { return GC_malloc_atomic((size_t)len + 1); }

int64_t st_timer(Closure f, int64_t ms, int64_t repeat) {
    int64_t id = table_add(&timers, f);
    js_timer((int32_t)id, (int32_t)ms, (int32_t)repeat);
    return id;
}

void st_clear_timer(int64_t id) {
    if (!timers || id < 0 || id >= timers->len) return;
    AT(timers, id) = NULL;
    js_clear_timer((int32_t)id);
}

__attribute__((export_name("st_timer_fire"))) void st_timer_fire(int32_t id, int32_t once) {
    if (!timers || id < 0 || id >= timers->len || !AT(timers, id)) return;
    Closure f = AT(timers, id);
    if (once) AT(timers, id) = NULL;
    ((void (*)(Closure))FN(f))(f);
}

void st_fetch(const char *method, const char *url, const char *body, Closure done) {
    int64_t id = table_add(&fetches, done);
    js_fetch((int32_t)id, method, url, body);
}

__attribute__((export_name("st_fetch_done"))) void st_fetch_done(int32_t id, int32_t status, const char *body) {
    if (!fetches || id < 0 || id >= fetches->len || !AT(fetches, id)) return;
    Closure f = AT(fetches, id);
    AT(fetches, id) = NULL;
    ((void (*)(Closure, int64_t, const char *))FN(f))(f, status, body);
}

char *st_storage_get(const char *key) { return js_storage_get(key); }
void st_storage_set(const char *key, const char *value) { js_storage_set(key, value); }
char *st_location(void) { return js_location(); }
void st_navigate(const char *path) { js_navigate(path); }
void st_set_title(const char *t) { js_set_title(t); }
const char *st_raw(const char *html) { return html; }
char *st_element_text(const char *id) { return js_element_text(id); }
