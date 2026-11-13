// stellang runtime: GC heap, strings, list growth, printing, and POSIX sockets for `import net`.
// Compiled by clang alongside every program; memory is managed by Boehm GC (-lgc).
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __linux__
#include <sys/sendfile.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
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

// JSON string literal: quotes, backslashes and control characters escaped
char *st_json_quote(const char *s) {
    size_t n = strlen(s);
    char *r = alloc(n * 6 + 3, 1, 1), *p = r;
    *p++ = '"';
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"': *p++ = '\\'; *p++ = '"'; break;
        case '\\': *p++ = '\\'; *p++ = '\\'; break;
        case '\n': *p++ = '\\'; *p++ = 'n'; break;
        case '\r': *p++ = '\\'; *p++ = 'r'; break;
        case '\t': *p++ = '\\'; *p++ = 't'; break;
        default:
            if (c < 0x20) p += sprintf(p, "\\u%04x", c);
            else *p++ = (char)c;
        }
    }
    *p++ = '"';
    *p = 0;
    return r;
}

// a JSON number (JSON has no nan or infinity: those become null)
char *st_json_num(double x) {
    if (isnan(x) || isinf(x)) return "null";
    return st_ftoa(x);
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

// ---- the event loop under std/http.st: non-blocking accept, poll, per-connection input buffers ----

typedef struct { char *data; size_t len, cap; } Buf;
static Buf *ins, *frags; // indexed by fd: unread input, and a fragmented WebSocket message
static int nfds;
static int64_t ws_last_op;

static Buf *buf(Buf **arr, int fd) {
    if (fd >= nfds) {
        int n = nfds ? nfds : 64;
        while (n <= fd) n *= 2;
        ins = realloc(ins, n * sizeof(Buf));
        frags = realloc(frags, n * sizeof(Buf));
        memset(ins + nfds, 0, (n - nfds) * sizeof(Buf));
        memset(frags + nfds, 0, (n - nfds) * sizeof(Buf));
        nfds = n;
    }
    return &(*arr)[fd];
}

static void buf_add(Buf *b, const char *p, size_t n) {
    if (b->len + n + 1 > b->cap) {
        b->cap = (b->len + n + 1) * 2;
        b->data = realloc(b->data, b->cap);
        if (!b->data) st_panic("panic: out of memory\n");
    }
    memcpy(b->data + b->len, p, n);
    b->len += n;
    b->data[b->len] = 0;
}

static void buf_eat(Buf *b, size_t n) {
    memmove(b->data, b->data + n, b->len - n);
    b->len -= n;
    if (b->data) b->data[b->len] = 0;
}

int64_t st_nonblock(int64_t fd) {
    int fl = fcntl((int)fd, F_GETFL, 0);
    return fl < 0 ? -1 : fcntl((int)fd, F_SETFL, fl | O_NONBLOCK);
}

// a waiting client, or -1 when there is none right now
int64_t st_accept_nb(int64_t fd) {
    int c = accept((int)fd, NULL, NULL);
    if (c < 0) return -1;
    struct timeval t = {.tv_sec = 10}; // a client that stops reading must not block the server forever
    setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof t);
    Buf *b = buf(&ins, c), *f = buf(&frags, c);
    b->len = f->len = 0;
    return c;
}

// the fds (of `fds`) that have input or hung up; waits at most `timeout_ms` (-1: forever)
Vec *st_poll(Vec *fds, int64_t timeout_ms) {
    int64_t n = fds->len, *fd = fds->data;
    struct pollfd *p = alloc(n, sizeof *p, 1);
    for (int64_t i = 0; i < n; i++) p[i] = (struct pollfd){.fd = (int)fd[i], .events = POLLIN};
    Vec *out = st_vec_new(0, 8, 1);
    int r;
    do r = poll(p, (nfds_t)n, (int)timeout_ms); while (r < 0 && errno == EINTR);
    for (int64_t i = 0; r > 0 && i < n; i++) {
        if (!p[i].revents) continue;
        if (out->len == out->cap) st_vec_grow(out, 8);
        ((int64_t *)out->data)[out->len++] = fd[i];
    }
    return out;
}

// read what has arrived into fd's buffer: 1 = ok, 0 = the peer closed, -1 = error or too much
int64_t st_fill(int64_t fd) {
    Buf *b = buf(&ins, (int)fd);
    char tmp[16384];
    for (;;) {
        ssize_t r = recv((int)fd, tmp, sizeof tmp, MSG_DONTWAIT);
        if (r > 0) {
            if (b->len + r > (64u << 20)) return -1;
            buf_add(b, tmp, (size_t)r);
            continue;
        }
        if (r == 0) return 0;
        if (errno == EINTR) continue;
        return errno == EAGAIN || errno == EWOULDBLOCK ? 1 : -1;
    }
}

// the next complete HTTP request in fd's buffer (headers + Content-Length body), or ""
char *st_http_take(int64_t fd) {
    Buf *b = buf(&ins, (int)fd);
    if (!b->len) return "";
    char *end = strstr(b->data, "\r\n\r\n");
    if (!end) return "";
    size_t head = (size_t)(end + 4 - b->data);
    long long body = 0;
    for (char *p = b->data; p && p < end; p = strstr(p + 1, "\n")) {
        if (strncasecmp(p + (*p == '\n'), "content-length:", 15) == 0) body = atoll(p + (*p == '\n') + 15);
    }
    if (body < 0) body = 0;
    if (b->len < head + (size_t)body) return "";
    char *r = mkstr(b->data, head + (size_t)body);
    buf_eat(b, head + (size_t)body);
    return r;
}

// the next complete WebSocket message in fd's buffer; st_ws_op() tells its kind (0 = none yet)
// 1 text, 2 binary, 8 close, 9 ping, 10 pong. Fragmented messages are joined.
char *st_ws_take(int64_t fd) {
    Buf *b = buf(&ins, (int)fd), *f = buf(&frags, (int)fd);
    for (;;) {
        ws_last_op = 0;
        unsigned char *d = (unsigned char *)b->data;
        if (b->len < 2) return "";
        int fin = d[0] & 0x80, op = d[0] & 0x0f, masked = d[1] & 0x80;
        uint64_t n = d[1] & 0x7f;
        size_t at = 2;
        if (n == 126) {
            if (b->len < 4) return "";
            n = (uint64_t)d[2] << 8 | d[3];
            at = 4;
        } else if (n == 127) {
            if (b->len < 10) return "";
            n = 0;
            for (int i = 0; i < 8; i++) n = n << 8 | d[2 + i];
            at = 10;
        }
        if (n > (64u << 20)) { ws_last_op = 8; return ""; }
        unsigned char mask[4] = {0};
        if (masked) {
            if (b->len < at + 4) return "";
            memcpy(mask, d + at, 4);
            at += 4;
        }
        if (b->len < at + n) return "";
        char *payload = alloc((int64_t)n + 1, 1, 1);
        for (uint64_t i = 0; i < n; i++) payload[i] = (char)(d[at + i] ^ mask[i % 4]);
        payload[n] = 0;
        buf_eat(b, at + n);
        if (op >= 8) { ws_last_op = op; return payload; } // control frames may come between fragments
        if (op != 0) { f->len = 0; buf_add(f, "", 0); f->data[0] = (char)op; f->len = 1; }
        if (!f->len) continue; // a continuation without a start
        buf_add(f, payload, n);
        if (!fin) continue;
        ws_last_op = f->data[0];
        char *r = mkstr(f->data + 1, f->len - 1);
        f->len = 0;
        return r;
    }
}

int64_t st_ws_op(void) { return ws_last_op; }

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 // macOS: SIGPIPE is ignored in st_init anyway
#endif

static int write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

int64_t st_ws_send(int64_t fd, int64_t op, const char *msg) {
    size_t n = strlen(msg), h = 2;
    unsigned char head[10];
    head[0] = 0x80 | (unsigned char)op;
    if (n < 126) {
        head[1] = (unsigned char)n;
    } else if (n < 65536) {
        head[1] = 126, head[2] = (unsigned char)(n >> 8), head[3] = (unsigned char)n, h = 4;
    } else {
        head[1] = 127, h = 10;
        for (int i = 0; i < 8; i++) head[2 + i] = (unsigned char)(n >> (56 - 8 * i));
    }
    return write_all((int)fd, (char *)head, h) || write_all((int)fd, msg, n) ? -1 : 0;
}

// forget fd's buffers and close it
void st_drop(int64_t fd) {
    if (fd < nfds) ins[fd].len = frags[fd].len = 0;
    close((int)fd);
}

int64_t st_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// ---- SHA-1 + base64, for the WebSocket handshake ----

static uint32_t rol(uint32_t x, int n) { return x << n | x >> (32 - n); }

static void sha1(const unsigned char *msg, size_t len, unsigned char out[20]) {
    uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
    size_t total = ((len + 8) / 64 + 1) * 64;
    unsigned char *m = alloc((int64_t)total, 1, 1);
    memset(m, 0, total);
    memcpy(m, msg, len);
    m[len] = 0x80;
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) m[total - 1 - i] = (unsigned char)(bits >> (8 * i));
    for (size_t c = 0; c < total; c += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++) w[i] = (uint32_t)m[c + 4 * i] << 24 | m[c + 4 * i + 1] << 16 | m[c + 4 * i + 2] << 8 | m[c + 4 * i + 3];
        for (int i = 16; i < 80; i++) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        uint32_t a = h[0], b = h[1], cc = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) f = (b & cc) | (~b & d), k = 0x5A827999;
            else if (i < 40) f = b ^ cc ^ d, k = 0x6ED9EBA1;
            else if (i < 60) f = (b & cc) | (b & d) | (cc & d), k = 0x8F1BBCDC;
            else f = b ^ cc ^ d, k = 0xCA62C1D6;
            uint32_t t = rol(a, 5) + f + e + k + w[i];
            e = d, d = cc, cc = rol(b, 30), b = a, a = t;
        }
        h[0] += a, h[1] += b, h[2] += cc, h[3] += d, h[4] += e;
    }
    for (int i = 0; i < 5; i++)
        for (int j = 0; j < 4; j++) out[4 * i + j] = (unsigned char)(h[i] >> (24 - 8 * j));
}

static char *base64(const unsigned char *p, size_t n) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char *r = alloc((int64_t)(n + 2) / 3 * 4 + 1, 1, 1), *o = r;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        *o++ = t[v >> 18 & 63];
        *o++ = t[v >> 12 & 63];
        *o++ = i + 1 < n ? t[v >> 6 & 63] : '=';
        *o++ = i + 2 < n ? t[v & 63] : '=';
    }
    *o = 0;
    return r;
}

char *st_ws_accept(const char *key) {
    char *s = st_concat(key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    unsigned char d[20];
    sha1((unsigned char *)s, strlen(s), d);
    return base64(d, 20);
}

// "a%20b+c" -> "a b c"
char *st_url_decode(const char *s) {
    char *r = alloc((int64_t)strlen(s) + 1, 1, 1), *o = r;
    for (; *s; s++) {
        if (*s == '+') *o++ = ' ';
        else if (*s == '%' && isxdigit((unsigned char)s[1]) && isxdigit((unsigned char)s[2])) {
            char h[3] = {s[1], s[2], 0};
            *o++ = (char)strtol(h, NULL, 16);
            s += 2;
        } else *o++ = *s;
    }
    *o = 0;
    return r;
}

// ---- files, for std/fs.st and res.send_file ----

// size in bytes of a regular file, or -1
int64_t st_file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) < 0 || !S_ISREG(st.st_mode)) return -1;
    return st.st_size;
}

bool st_is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// write `head`, then the file's bytes (binary-safe)
int64_t st_send_file(int64_t fd, const char *head, const char *path) {
    int f = open(path, O_RDONLY);
    if (f < 0) return -1;
    struct stat st;
    fstat(f, &st);
    int64_t r = write_all((int)fd, head, strlen(head));
#ifdef __linux__
    off_t off = 0;
    while (!r && off < st.st_size) {
        ssize_t w = sendfile((int)fd, f, &off, (size_t)(st.st_size - off));
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) r = -1;
    }
#else
    char buf[65536];
    for (ssize_t n; !r && (n = read(f, buf, sizeof buf)) != 0;) {
        if (n < 0 && errno == EINTR) continue;
        r = n < 0 ? -1 : write_all((int)fd, buf, (size_t)n);
    }
#endif
    close(f);
    return r;
}

char *st_read_file(const char *path) {
    last_error = "";
    FILE *f = fopen(path, "rb");
    if (!f) { failed(); return ""; }
    size_t cap = 4096, n = 0, r;
    char *b = alloc((int64_t)cap + 1, 1, 1);
    while ((r = fread(b + n, 1, cap - n, f)) > 0) {
        n += r;
        if (n == cap) {
            char *nb = alloc((int64_t)cap * 2 + 1, 1, 1);
            memcpy(nb, b, n);
            b = nb;
            cap *= 2;
        }
    }
    if (ferror(f)) failed();
    fclose(f);
    b[n] = 0;
    return b;
}

int64_t st_write_file(const char *path, const char *data, int64_t append) {
    last_error = "";
    FILE *f = fopen(path, append ? "ab" : "wb");
    if (!f) { failed(); return -1; }
    size_t n = strlen(data);
    int bad = fwrite(data, 1, n, f) != n;
    if (fclose(f) || bad) { failed(); return -1; }
    return 0;
}

int64_t st_remove_file(const char *path) {
    last_error = "";
    if (remove(path) < 0) { failed(); return -1; }
    return 0;
}

int64_t st_mkdir(const char *path) {
    last_error = "";
    if (mkdir(path, 0777) < 0 && errno != EEXIST) { failed(); return -1; }
    return 0;
}

// the names in a directory (sorted, without . and ..)
Vec *st_list_dir(const char *path) {
    last_error = "";
    Vec *v = st_vec_new(0, sizeof(char *), 0);
    DIR *d = opendir(path);
    if (!d) { failed(); return v; }
    for (struct dirent *e; (e = readdir(d));) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) st_vec_push_str(v, mkstr(e->d_name, strlen(e->d_name)));
    }
    closedir(d);
    qsort(v->data, v->len, 8, cmp_s);
    return v;
}

// UTF-8 encoding of code point `c`
char *st_chr(int64_t c) {
    char b[5] = {0};
    if (c < 0x80) b[0] = (char)c;
    else if (c < 0x800) b[0] = (char)(0xC0 | c >> 6), b[1] = (char)(0x80 | (c & 63));
    else if (c < 0x10000) b[0] = (char)(0xE0 | c >> 12), b[1] = (char)(0x80 | (c >> 6 & 63)), b[2] = (char)(0x80 | (c & 63));
    else b[0] = (char)(0xF0 | c >> 18), b[1] = (char)(0x80 | (c >> 12 & 63)), b[2] = (char)(0x80 | (c >> 6 & 63)), b[3] = (char)(0x80 | (c & 63));
    return mkstr(b, strlen(b));
}
