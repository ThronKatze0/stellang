// stellang browser runtime (compiled with runtime.c for `stellang --web`): a garbage collector for
// WebAssembly, and the glue between stellang apps and the page (rendering, events, state, timers,
// fetch). The page side lives in loader.js.
// (appended to runtime.c, whose includes, Vec and st_vec_* it uses)

// ---- garbage collector (runtime_gc.c) ----
//
// Pages come straight from `memory.grow`. WebAssembly can't scan its own stack, so collection only
// happens between calls from JavaScript, when no stellang code is running: the only roots are then
// the globals (the data segment) and what they reach.

extern char __global_base, __data_end; // the data segment, from wasm-ld

static void *gc_grow(uint32_t n) {
    int32_t old = __builtin_wasm_memory_grow(0, n);
    if (old < 0) {
        static const char m[] = "panic: out of memory\n";
        st_panic(m);
    }
    return (void *)((uintptr_t)old * PAGE);
}

static void gc_roots(void) { gc_scan((uintptr_t)&__global_base, (uintptr_t)&__data_end); }

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
