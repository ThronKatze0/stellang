// stellang runtime: GC heap, strings, list growth, printing, and POSIX sockets for `import net`.
// Compiled by clang alongside every program; memory is managed by Boehm GC (-lgc).
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

void GC_init(void);
void *GC_malloc(size_t);
void *GC_malloc_atomic(size_t);
void *GC_realloc(void *, size_t);

typedef struct { int64_t len, cap; void *data; } Vec; // matches %st.vec

_Noreturn void st_panic(const char *m) {
    fflush(stdout);
    fputs(m, stderr);
    exit(101);
}

_Noreturn void st_panic_msg(const char *where, const char *msg) {
    fflush(stdout);
    fprintf(stderr, "%s: panic: %s\n", where, msg);
    exit(101);
}

// `fn main() -> void!` returned an error
_Noreturn void st_fail(const char *msg) {
    fflush(stdout);
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

static void *alloc(int64_t n, int64_t esz, int atomic) {
    size_t bytes;
    if (n < 0 || __builtin_mul_overflow((size_t)n, (size_t)esz, &bytes)) st_panic("panic: out of memory\n");
    void *p = atomic ? GC_malloc_atomic(bytes ? bytes : 1) : GC_malloc(bytes ? bytes : 1);
    if (!p) st_panic("panic: out of memory\n");
    return p;
}

void *st_alloc(int64_t size) { return alloc(size, 1, 0); } // objects, closures, boxes (zeroed)

void st_init(void) {
    GC_init();
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN); // a client hanging up must not kill a server
}

Vec *st_vec_new(int64_t n, int64_t esz, int64_t atomic) {
    Vec *v = alloc(1, sizeof(Vec), 0);
    v->cap = n < 4 ? 4 : n;
    v->data = alloc(v->cap, esz, atomic);
    v->len = n;
    return v;
}

void st_vec_grow(Vec *v, int64_t esz) {
    size_t bytes;
    if (__builtin_mul_overflow((size_t)v->cap * 2, (size_t)esz, &bytes)) st_panic("panic: out of memory\n");
    void *d = GC_realloc(v->data, bytes ? bytes : 1); // keeps the pointer-free ("atomic") kind
    if (!d) st_panic("panic: out of memory\n");
    v->data = d;
    v->cap *= 2;
}

static char *mkstr(const char *p, size_t n) {
    char *r = alloc(n + 1, 1, 1);
    memcpy(r, p, n);
    r[n] = 0;
    return r;
}

void st_vec_push_str(Vec *v, char *s) {
    if (v->len == v->cap) st_vec_grow(v, sizeof(char *));
    ((char **)v->data)[v->len++] = s;
}

void st_print_s(const char *s) { fputs(s, stdout); }
void st_nl(void) { putchar('\n'); }

char *st_env(const char *name) {
    const char *v = getenv(name);
    return v ? mkstr(v, strlen(v)) : "";
}

// ---- strings (immutable, NUL-terminated, GC-allocated) ----

int64_t st_strlen(const char *s) { return strlen(s); }
bool st_streq(const char *a, const char *b) { return strcmp(a, b) == 0; }

char *st_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *r = alloc(la + lb + 1, 1, 1);
    memcpy(r, a, la);
    memcpy(r + la, b, lb + 1);
    return r;
}

char *st_itoa(int64_t n) {
    char b[24];
    return mkstr(b, snprintf(b, sizeof b, "%lld", (long long)n));
}

// shortest text that reads back as the same double; always has a `.` or exponent ("1000.0", "0.1", "1e+300")
char *st_ftoa(double x) {
    char b[64];
    if (isnan(x)) return "nan";
    if (isinf(x)) return x > 0 ? "inf" : "-inf";
    int plain = fabs(x) >= 1e-4 && fabs(x) < 1e16;
    for (int p = plain ? 0 : 1; p <= (plain ? 24 : 17); p++) {
        snprintf(b, sizeof b, plain ? "%.*f" : "%.*g", p, x);
        if (strtod(b, NULL) == x) break;
    }
    if (!strpbrk(b, ".e")) strcat(b, ".0");
    return mkstr(b, strlen(b));
}

// float("1.5"): NULL on success (value in *out), otherwise the error message
char *st_parse_float(const char *s, double *out) {
    char *end;
    errno = 0;
    double v = strtod(s, &end);
    if (*s == 0 || isspace((unsigned char)*s) || *end != 0 || errno) {
        *out = 0;
        return st_concat(st_concat("not a number: \"", s), "\"");
    }
    *out = v;
    return NULL;
}

// "a\"b" -> "\"a\\\"b\"", for showing strs inside lists and maps
char *st_quote(const char *s) {
    char *r = alloc(strlen(s) * 2 + 3, 1, 1), *p = r;
    *p++ = '"';
    for (; *s; s++) {
        char c = *s == '\n' ? 'n' : *s == '\t' ? 't' : *s;
        if (c != *s || c == '"' || c == '\\') *p++ = '\\';
        *p++ = c;
    }
    *p++ = '"';
    *p = 0;
    return r;
}

// int("42"): NULL on success (value in *out), otherwise the error message
char *st_parse_int(const char *s, int64_t *out) {
    char *end;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (*s == 0 || isspace((unsigned char)*s) || *end != 0 || errno) {
        *out = 0;
        return st_concat(st_concat("not a number: \"", s), "\"");
    }
    *out = v;
    return NULL;
}

char *st_slice(const char *s, int64_t from, int64_t to, const char *where) {
    int64_t n = strlen(s);
    if (from < 0 || to < from || to > n) st_panic(where);
    return mkstr(s + from, to - from);
}

int64_t st_find(const char *s, const char *sub) {
    const char *p = strstr(s, sub);
    return p ? p - s : -1;
}

Vec *st_split(const char *s, const char *sep) {
    Vec *v = st_vec_new(0, sizeof(char *), 0);
    size_t ls = strlen(sep);
    for (const char *p; ls && (p = strstr(s, sep)); s = p + ls) st_vec_push_str(v, mkstr(s, p - s));
    st_vec_push_str(v, mkstr(s, strlen(s)));
    return v;
}

char *st_trim(const char *s) {
    while (isspace((unsigned char)*s)) s++;
    size_t n = strlen(s);
    while (n && isspace((unsigned char)s[n - 1])) n--;
    return mkstr(s, n);
}

bool st_starts(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }
bool st_contains(const char *s, const char *p) { return strstr(s, p) != NULL; }
bool st_ends(const char *s, const char *p) {
    size_t n = strlen(s), m = strlen(p);
    return m <= n && strcmp(s + n - m, p) == 0;
}

static char *map_case(const char *s, int (*f)(int)) {
    size_t n = strlen(s);
    char *r = mkstr(s, n);
    for (size_t i = 0; i < n; i++) r[i] = (char)f((unsigned char)r[i]);
    return r;
}
char *st_lower(const char *s) { return map_case(s, tolower); }
char *st_upper(const char *s) { return map_case(s, toupper); }

char *st_replace(const char *s, const char *from, const char *to) {
    if (!*from) return (char *)s;
    Vec *parts = st_split(s, from);
    char *r = ((char **)parts->data)[0];
    for (int64_t i = 1; i < parts->len; i++) r = st_concat(st_concat(r, to), ((char **)parts->data)[i]);
    return r;
}

char *st_char_at(const char *s, int64_t i, const char *where) {
    if (i < 0 || i >= (int64_t)strlen(s)) st_panic(where);
    return mkstr(s + i, 1);
}

char *st_repeat(const char *s, int64_t n) {
    size_t l = strlen(s);
    if (n <= 0 || !l) return "";
    size_t bytes;
    if (__builtin_mul_overflow((size_t)n, l, &bytes)) st_panic("panic: out of memory\n");
    char *r = alloc(bytes + 1, 1, 1);
    for (int64_t i = 0; i < n; i++) memcpy(r + i * l, s, l);
    r[n * l] = 0;
    return r;
}

Vec *st_chars(const char *s) {
    Vec *v = st_vec_new(0, sizeof(char *), 0);
    for (; *s; s++) st_vec_push_str(v, mkstr(s, 1));
    return v;
}

Vec *st_lines(const char *s) {
    Vec *v = st_vec_new(0, sizeof(char *), 0);
    while (*s) {
        size_t n = strcspn(s, "\n");
        st_vec_push_str(v, mkstr(s, n && s[n - 1] == '\r' ? n - 1 : n));
        s += n + (s[n] == '\n');
    }
    return v;
}

char *st_trim_start(const char *s) {
    while (isspace((unsigned char)*s)) s++;
    return mkstr(s, strlen(s));
}

char *st_trim_end(const char *s) {
    size_t n = strlen(s);
    while (n && isspace((unsigned char)s[n - 1])) n--;
    return mkstr(s, n);
}

int64_t st_count(const char *s, const char *sub) {
    size_t l = strlen(sub);
    int64_t n = 0;
    if (!l) return 0;
    for (const char *p; (p = strstr(s, sub)); s = p + l) n++;
    return n;
}

char *st_reverse(const char *s) {
    size_t n = strlen(s);
    char *r = alloc(n + 1, 1, 1);
    for (size_t i = 0; i < n; i++) r[i] = s[n - 1 - i];
    r[n] = 0;
    return r;
}

int64_t st_strcmp(const char *a, const char *b) { return strcmp(a, b); }

char *st_join(Vec *v, const char *sep) {
    size_t n = 0, ls = strlen(sep);
    char **xs = v->data;
    for (int64_t i = 0; i < v->len; i++) n += strlen(xs[i]) + (i ? ls : 0);
    char *r = alloc(n + 1, 1, 1), *p = r;
    for (int64_t i = 0; i < v->len; i++) {
        if (i) { memcpy(p, sep, ls); p += ls; }
        size_t k = strlen(xs[i]);
        memcpy(p, xs[i], k);
        p += k;
    }
    *p = 0;
    return r;
}

// ---- lists: generic over the element size ----

Vec *st_vec_slice(Vec *v, int64_t from, int64_t to, int64_t esz, int64_t atomic, const char *where) {
    if (from < 0 || to < from || to > v->len) st_panic(where);
    Vec *r = st_vec_new(to - from, esz, atomic);
    memcpy(r->data, (char *)v->data + from * esz, (to - from) * esz);
    return r;
}

// open a gap at i (0..len); the caller stores the new element there
void st_vec_insert(Vec *v, int64_t i, int64_t esz, const char *where) {
    if (i < 0 || i > v->len) st_panic(where);
    if (v->len == v->cap) st_vec_grow(v, esz);
    char *d = v->data;
    memmove(d + (i + 1) * esz, d + i * esz, (v->len - i) * esz);
    v->len++;
}

// close the gap at i; the caller read the element first
void st_vec_remove(Vec *v, int64_t i, int64_t esz) {
    char *d = v->data;
    memmove(d + i * esz, d + (i + 1) * esz, (v->len - i - 1) * esz);
    v->len--;
}

void st_vec_reverse(Vec *v, int64_t esz) {
    char *d = v->data, t[8];
    for (int64_t i = 0, j = v->len - 1; i < j; i++, j--) {
        memcpy(t, d + i * esz, esz);
        memcpy(d + i * esz, d + j * esz, esz);
        memcpy(d + j * esz, t, esz);
    }
}

static int cmp_i(const void *a, const void *b) { int64_t x = *(int64_t *)a, y = *(int64_t *)b; return (x > y) - (x < y); }
static int cmp_f(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return (x > y) - (x < y); }
static int cmp_s(const void *a, const void *b) { return strcmp(*(char **)a, *(char **)b); }

// kind: 0 int, 1 float, 2 str
void st_vec_sort(Vec *v, int64_t kind) {
    qsort(v->data, v->len, 8, kind == 0 ? cmp_i : kind == 1 ? cmp_f : cmp_s);
}

// ---- maps and sets: insertion-ordered hash tables of 8-byte slots (a set is a map without values) ----
// Entries live in dense arrays in insertion order; `idx` is an open-addressing table of entry index + 1.

typedef struct {
    int64_t n, live, icap; // entries used (incl. removed), entries alive, idx size (power of 2)
    int64_t *keys, *vals, *idx;
    char *dead;
    int64_t str; // keys are strs (compare contents, not pointers)
} Map;

static uint64_t hash(const Map *m, int64_t k) {
    uint64_t h = 1469598103934665603u;
    if (m->str) {
        for (const char *p = (const char *)k; *p; p++) h = (h ^ (unsigned char)*p) * 1099511628211u;
        return h;
    }
    h = (uint64_t)k * 0x9E3779B97F4A7C15u;
    return h ^ (h >> 29);
}

static int64_t slot(const Map *m, int64_t k) {
    uint64_t mask = m->icap - 1;
    for (uint64_t i = hash(m, k) & mask;; i = (i + 1) & mask) {
        int64_t e = m->idx[i] - 1;
        if (e < 0 || (m->str ? strcmp((char *)m->keys[e], (char *)k) == 0 : m->keys[e] == k)) return i;
    }
}

static int64_t entry(const Map *m, int64_t k) {
    if (!m->icap) return -1;
    int64_t e = m->idx[slot(m, k)] - 1;
    return e >= 0 && !m->dead[e] ? e : -1;
}

static void rehash(Map *m) {
    int64_t cap = 8;
    while (cap < m->live * 4) cap *= 2;
    int64_t *keys = alloc(cap / 2, 8, 0), *vals = alloc(cap / 2, 8, 0), n = 0;
    for (int64_t i = 0; i < m->n; i++)
        if (!m->dead[i]) { keys[n] = m->keys[i]; vals[n] = m->vals[i]; n++; }
    m->keys = keys, m->vals = vals, m->n = n, m->icap = cap;
    m->dead = alloc(cap / 2, 1, 1);
    memset(m->dead, 0, cap / 2);
    m->idx = alloc(cap, 8, 1);
    memset(m->idx, 0, cap * 8);
    for (int64_t i = 0; i < n; i++) m->idx[slot(m, keys[i])] = i + 1;
}

Map *st_map_new(int64_t str) {
    Map *m = alloc(1, sizeof(Map), 0);
    m->str = str;
    return m;
}

int64_t st_map_len(Map *m) { return m->live; }

void st_map_set(Map *m, int64_t k, int64_t v) {
    int64_t e = entry(m, k);
    if (e >= 0) { m->vals[e] = v; return; }
    if (m->n == m->icap / 2) rehash(m);
    m->keys[m->n] = k, m->vals[m->n] = v;
    m->idx[slot(m, k)] = ++m->n; // a removed key comes back at the end, like Python and JS
    m->live++;
}

bool st_map_get(Map *m, int64_t k, int64_t *out) {
    int64_t e = entry(m, k);
    if (e >= 0 && out) *out = m->vals[e];
    return e >= 0;
}

bool st_map_remove(Map *m, int64_t k) {
    int64_t e = entry(m, k);
    if (e < 0) return false;
    m->dead[e] = 1;
    m->live--;
    return true;
}

// a snapshot of the keys (which = 0) or values (1) as a list with `esz`-byte elements
Vec *st_map_list(Map *m, int64_t which, int64_t esz, int64_t atomic) {
    Vec *v = st_vec_new(m->live, esz, atomic);
    int64_t *src = which ? m->vals : m->keys, j = 0;
    for (int64_t i = 0; i < m->n; i++)
        if (!m->dead[i]) memcpy((char *)v->data + j++ * esz, &src[i], esz); // little-endian: low bytes first
    return v;
}

// ---- sockets, used by std/net.st through `extern fn` ----
// Each call clears the last error; on failure it returns -1 (or "") and st_error() explains why.

static const char *last_error = "";
static void failed(void) { last_error = mkstr(strerror(errno), strlen(strerror(errno))); }
const char *st_error(void) { return last_error; }

int64_t st_listen(int64_t port) {
    last_error = "";
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (fd < 0 || setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0 ||
        bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 128) < 0) {
        failed();
        if (fd >= 0) close(fd);
        return -1;
    }
    return fd;
}

int64_t st_accept(int64_t fd) {
    last_error = "";
    int c = accept((int)fd, NULL, NULL);
    if (c < 0) { failed(); return -1; }
    struct timeval t = {.tv_sec = 5}; // a silent client must not hang the server forever
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
    return c;
}

// Reads one HTTP-style message: until the blank line after the headers, plus Content-Length bytes.
// ponytail: bodies with NUL bytes get cut off (strings are C strings); 16 MiB cap
char *st_read(int64_t fd) {
    last_error = "";
    size_t cap = 4096, n = 0;
    char *b = alloc(cap + 1, 1, 1);
    for (;;) {
        if (n == cap) {
            if (cap >= (1u << 24)) break;
            char *nb = alloc(cap * 2 + 1, 1, 1);
            memcpy(nb, b, n);
            b = nb;
            cap *= 2;
        }
        ssize_t r = read((int)fd, b + n, cap - n);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { failed(); return ""; }
        if (r == 0) break;
        n += (size_t)r;
        b[n] = 0;
        char *end = strstr(b, "\r\n\r\n");
        if (end) {
            size_t head = (size_t)(end + 4 - b);
            char *cl = strcasestr(b, "\ncontent-length:");
            long long body = cl && cl < end ? atoll(cl + 16) : 0;
            if (n >= head + (size_t)(body > 0 ? body : 0)) break;
        }
    }
    b[n] = 0;
    return b;
}

int64_t st_write(int64_t fd, const char *s) {
    last_error = "";
    size_t n = strlen(s), off = 0;
    while (off < n) {
        ssize_t w = write((int)fd, s + off, n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { failed(); return -1; }
        off += (size_t)w;
    }
    return (int64_t)off;
}

void st_close(int64_t fd) { close((int)fd); }
