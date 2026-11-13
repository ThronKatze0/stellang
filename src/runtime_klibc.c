// The C library for `stellang --kernel` (bare metal): just what runtime.c uses. It comes first in
// the kernel's C file, ahead of runtime.c (which skips its #includes then), runtime_gc.c and
// runtime_kernel.c. Output goes to the console (`kputs`, in runtime_kernel.c).
//
// Floats: printf's %f/%g and strtod are simple, not bit-exact like a hosted libc. Values that fit
// in 53 bits with up to 22 decimal places round-trip; the last digit of huge or tiny ones may differ.

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef long ssize_t;
typedef struct FILE FILE;
#define stdout ((FILE *)1)
#define stderr ((FILE *)2)
#define EOF (-1)

void kputs(const char *s, size_t n); // the console

int errno;
#define ERANGE 34
static const char *strerror(int e) { return e == ERANGE ? "out of range" : "error"; }

// ---- memory and strings ----

void *memcpy(void *d, const void *s, size_t n) {
    char *a = d;
    const char *b = s;
    if (!(((uintptr_t)a | (uintptr_t)b | n) & 7)) {
        for (size_t i = 0; i < n; i += 8) *(uint64_t *)(a + i) = *(const uint64_t *)(b + i);
        return d;
    }
    while (n--) *a++ = *b++;
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    char *a = d;
    const char *b = s;
    if (a < b) return memcpy(d, s, n);
    while (n--) a[n] = b[n];
    return d;
}

void *memset(void *d, int c, size_t n) {
    unsigned char *a = d;
    if (!c && !(((uintptr_t)a | n) & 7)) {
        for (size_t i = 0; i < n; i += 8) *(uint64_t *)(a + i) = 0;
        return d;
    }
    while (n--) *a++ = (unsigned char)c;
    return d;
}

int memcmp(const void *x, const void *y, size_t n) {
    const unsigned char *a = x, *b = y;
    for (; n; n--, a++, b++)
        if (*a != *b) return *a - *b;
    return 0;
}

void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    for (; n; n--, p++)
        if (*p == (unsigned char)c) return (void *)p;
    return NULL;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) a++, b++;
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    for (; n; n--, a++, b++) {
        if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
        if (!*a) return 0;
    }
    return 0;
}

char *strchr(const char *s, int c) {
    for (;; s++) {
        if (*s == (char)c) return (char *)s;
        if (!*s) return NULL;
    }
}

char *strrchr(const char *s, int c) {
    const char *r = NULL;
    for (;; s++) {
        if (*s == (char)c) r = s;
        if (!*s) return (char *)r;
    }
}

char *strstr(const char *h, const char *n) {
    size_t k = strlen(n);
    for (; *h; h++)
        if (!strncmp(h, n, k)) return (char *)h;
    return k ? NULL : (char *)h;
}

char *strpbrk(const char *s, const char *set) {
    for (; *s; s++)
        if (strchr(set, *s)) return (char *)s;
    return NULL;
}

char *strcpy(char *d, const char *s) {
    memcpy(d, s, strlen(s) + 1);
    return d;
}

char *strcat(char *d, const char *s) {
    strcpy(d + strlen(d), s);
    return d;
}

int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalpha(int c) { return (c | 32) >= 'a' && (c | 32) <= 'z'; }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isxdigit(int c) { return isdigit(c) || ((c | 32) >= 'a' && (c | 32) <= 'f'); }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int toupper(int c) { return islower(c) ? c - 32 : c; }
int tolower(int c) { return isupper(c) ? c + 32 : c; }

// ---- numbers ----

#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define fabs(x) __builtin_fabs(x)

double sqrt(double x) {
    double r;
    __asm__("fsqrt.d %0, %1" : "=f"(r) : "f"(x));
    return r;
}

double floor(double x) {
    if (!(fabs(x) < 4503599627370496.0)) return x; // 2^52: already whole (or nan/inf)
    double t = (double)(int64_t)x;
    return t > x ? t - 1 : t;
}
double ceil(double x) { return -floor(-x); }
double round(double x) { return x < 0 ? -floor(-x + 0.5) : floor(x + 0.5); }
double trunc(double x) { return x < 0 ? ceil(x) : floor(x); }
double fmod(double x, double y) {
    if (y == 0 || isinf(x) || isnan(x) || isnan(y)) return __builtin_nan("");
    if (isinf(y)) return x;
    double q = trunc(x / y), r = x - q * y;
    // (the quotient can be off by one when x/y rounds; nudge back into range)
    if (fabs(r) >= fabs(y)) r -= (r > 0) == (y > 0) ? y : -y;
    return r;
}

static const double P10[] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
                             1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};

// x * 10^e
static double scale10(double x, int e) {
    while (e > 22) x *= 1e22, e -= 22;
    while (e < -22) x /= 1e22, e += 22;
    return e >= 0 ? x * P10[e] : x / P10[-e];
}

long long strtoll(const char *s, char **end, int base) {
    const char *p = s;
    while (isspace(*p)) p++;
    bool neg = *p == '-';
    if (*p == '-' || *p == '+') p++;
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] | 32) == 'x' && isxdigit(p[2])) p += 2, base = 16;
    if (base == 0) base = 10;
    unsigned long long v = 0, lim = neg ? 9223372036854775808ull : 9223372036854775807ull;
    const char *start = p;
    bool over = false;
    for (;; p++) {
        int d = isdigit(*p) ? *p - '0' : isalpha(*p) ? (*p | 32) - 'a' + 10 : 99;
        if (d >= base) break;
        if (v > (lim - (unsigned)d) / (unsigned)base) over = true;
        else v = v * (unsigned)base + (unsigned)d;
    }
    if (end) *end = (char *)(p == start ? s : p);
    if (over) {
        errno = ERANGE;
        return neg ? (-9223372036854775807ll - 1) : 9223372036854775807ll;
    }
    return neg ? (long long)(0 - v) : (long long)v;
}
long strtol(const char *s, char **end, int base) { return (long)strtoll(s, end, base); }
long long atoll(const char *s) { return strtoll(s, NULL, 10); }
int atoi(const char *s) { return (int)strtoll(s, NULL, 10); }

double strtod(const char *s, char **end) {
    const char *p = s;
    while (isspace(*p)) p++;
    bool neg = *p == '-';
    if (*p == '-' || *p == '+') p++;
    if (!strncmp(p, "inf", 3) || !strncmp(p, "nan", 3)) {
        double v = p[0] == 'i' ? __builtin_inf() : __builtin_nan("");
        p += 3;
        if (v == __builtin_inf() && !strncmp(p, "inity", 5)) p += 5;
        if (end) *end = (char *)p;
        return neg ? -v : v;
    }
    uint64_t m = 0;
    int e = 0, digits = 0;
    const char *start = p;
    for (; isdigit(*p); p++, digits++) {
        if (m < 100000000000000000ull) m = m * 10 + (uint64_t)(*p - '0');
        else e++;
    }
    if (*p == '.') {
        for (p++; isdigit(*p); p++, digits++) {
            if (m < 100000000000000000ull) m = m * 10 + (uint64_t)(*p - '0'), e--;
        }
    }
    if (!digits) {
        if (end) *end = (char *)s;
        return 0;
    }
    if ((*p | 32) == 'e') {
        const char *q = p + 1;
        bool eneg = *q == '-';
        if (*q == '-' || *q == '+') q++;
        if (isdigit(*q)) {
            int x = 0;
            for (; isdigit(*q); q++)
                if (x < 10000) x = x * 10 + (*q - '0');
            e += eneg ? -x : x;
            p = q;
        }
    }
    (void)start;
    if (end) *end = (char *)p;
    double v = m == 0 ? 0 : e > 330 ? __builtin_inf() : e < -360 ? 0 : scale10((double)m, e);
    if (isinf(v)) errno = ERANGE;
    return neg ? -v : v;
}

// ---- formatting ----

typedef struct {
    char *p;
    size_t n, cap;
} Out;

static void out_c(Out *o, char c) {
    if (o->n + 1 < o->cap) o->p[o->n] = c;
    o->n++;
}

static void out_s(Out *o, const char *s, size_t n) {
    while (n--) out_c(o, *s++);
}

static void out_pad(Out *o, const char *s, size_t n, int width, bool left, char pad) {
    int fill = width > (int)n ? width - (int)n : 0;
    if (!left && pad == '0' && n && (s[0] == '-' || s[0] == '+')) out_c(o, *s++), n--;
    if (!left) while (fill--) out_c(o, pad);
    out_s(o, s, n);
    if (left) while (fill-- > 0) out_c(o, ' ');
}

static size_t fmt_u(char *b, unsigned long long v, unsigned base, bool upper) {
    char t[24];
    size_t n = 0;
    do t[n++] = (upper ? "0123456789ABCDEF" : "0123456789abcdef")[v % base], v /= base;
    while (v);
    for (size_t i = 0; i < n; i++) b[i] = t[n - 1 - i];
    return n;
}

// the decimal digits of x >= 0 rounded to `frac` places: `int_digits` then `frac` digits, no dot
static size_t fmt_fixed_digits(char *b, size_t cap, double x, int frac) {
    double scaled = scale10(x, frac) + 0.5;
    if (scaled < 1.8e19) {
        unsigned long long v = (unsigned long long)scaled;
        size_t n = fmt_u(b, v, 10, false);
        if ((int)n <= frac) { // pad with leading zeros so there is one integer digit
            size_t z = (size_t)frac + 1 - n;
            memmove(b + z, b, n);
            memset(b, '0', z);
            n += z;
        }
        return n;
    }
    // too big for 64 bits: the integer part by repeated division, then zeros for the fraction
    char t[400];
    size_t n = 0;
    double ip = floor(x);
    do {
        double q = floor(ip / 10);
        int d = (int)(ip - q * 10);
        t[n++] = (char)('0' + (d < 0 ? 0 : d > 9 ? 9 : d));
        ip = q;
    } while (ip >= 1 && n < sizeof t);
    size_t k = 0;
    for (size_t i = 0; i < n && k < cap; i++) b[k++] = t[n - 1 - i];
    for (int i = 0; i < frac && k < cap; i++) b[k++] = '0';
    return k;
}

static void fmt_double(Out *o, double x, int prec, char conv, int width, bool left, char pad, bool plus) {
    char b[512];
    size_t n = 0;
    if (x < 0 || (x == 0 && __builtin_signbit(x))) b[n++] = '-', x = -x;
    else if (plus) b[n++] = '+';
    if (isnan(x) || isinf(x)) {
        memcpy(b + n, isnan(x) ? "nan" : "inf", 3);
        out_pad(o, b, n + 3, width, left, ' ');
        return;
    }
    if (prec < 0) prec = 6;
    if (prec > 40) prec = 40;
    if (conv == 'f') {
        char d[440];
        size_t k = fmt_fixed_digits(d, sizeof d, x, prec);
        size_t ip = k - (size_t)prec;
        memcpy(b + n, d, ip), n += ip;
        if (prec) b[n++] = '.', memcpy(b + n, d + ip, (size_t)prec), n += (size_t)prec;
        out_pad(o, b, n, width, left, pad);
        return;
    }
    // %g / %e: `prec` significant digits
    bool g = conv == 'g';
    if (g && prec == 0) prec = 1;
    int sig = g ? prec : prec + 1;
    int e = 0;
    if (x != 0) {
        double y = x;
        while (y >= 1e22) y /= 1e22, e += 22;
        while (y >= 10) y /= 10, e++;
        while (y < 1e-22) y *= 1e22, e -= 22;
        while (y < 1) y *= 10, e--;
    }
    // the significant digits, rounded (which can carry into a new digit: 9.99 -> 10.0)
    char d[64];
    unsigned long long v = (unsigned long long)(scale10(x, sig - 1 - e) + 0.5);
    size_t k = fmt_u(d, v, 10, false);
    if ((int)k > sig) e++, k--;
    while ((int)k < sig) d[k++] = '0';
    bool expo = !g || e < -4 || e >= prec;
    if (expo) {
        int keep = sig;
        if (g) while (keep > 1 && d[keep - 1] == '0') keep--;
        b[n++] = d[0];
        if (keep > 1) b[n++] = '.', memcpy(b + n, d + 1, (size_t)keep - 1), n += (size_t)keep - 1;
        b[n++] = 'e';
        b[n++] = e < 0 ? '-' : '+';
        int ae = e < 0 ? -e : e;
        if (ae < 10) b[n++] = '0';
        n += fmt_u(b + n, (unsigned)ae, 10, false);
    } else {
        // plain: e+1 integer digits (or "0.000ddd")
        char t[128];
        size_t m = 0;
        if (e < 0) {
            t[m++] = '0', t[m++] = '.';
            for (int i = -1; i > e; i--) t[m++] = '0';
            memcpy(t + m, d, (size_t)sig), m += (size_t)sig;
        } else {
            memcpy(t, d, (size_t)e + 1), m = (size_t)e + 1;
            if (sig > e + 1) t[m++] = '.', memcpy(t + m, d + e + 1, (size_t)(sig - e - 1)), m += (size_t)(sig - e - 1);
        }
        if (memchr(t, '.', m)) {
            while (t[m - 1] == '0') m--;
            if (t[m - 1] == '.') m--;
        }
        memcpy(b + n, t, m), n += m;
    }
    out_pad(o, b, n, width, left, pad);
}

int vsnprintf(char *buf, size_t cap, const char *f, va_list ap) {
    Out o = {buf, 0, cap};
    for (; *f; f++) {
        if (*f != '%') {
            out_c(&o, *f);
            continue;
        }
        f++;
        bool left = false, plus = false;
        char pad = ' ';
        for (;; f++) {
            if (*f == '-') left = true;
            else if (*f == '0') pad = '0';
            else if (*f == '+') plus = true;
            else if (*f != ' ' && *f != '#') break;
        }
        int width = 0, prec = -1;
        if (*f == '*') width = va_arg(ap, int), f++;
        else while (isdigit(*f)) width = width * 10 + (*f++ - '0');
        if (*f == '.') {
            f++;
            prec = 0;
            if (*f == '*') prec = va_arg(ap, int), f++;
            else while (isdigit(*f)) prec = prec * 10 + (*f++ - '0');
        }
        int lng = 0;
        while (*f == 'l' || *f == 'z' || *f == 'j' || *f == 't' || *f == 'h') lng += *f != 'h', f++;
        char t[32];
        size_t n;
        switch (*f) {
        case 'd':
        case 'i': {
            long long v = lng ? va_arg(ap, long long) : va_arg(ap, int);
            n = 0;
            if (v < 0) t[n++] = '-';
            else if (plus) t[n++] = '+';
            n += fmt_u(t + n, v < 0 ? 0ull - (unsigned long long)v : (unsigned long long)v, 10, false);
            out_pad(&o, t, n, width, left, pad);
            break;
        }
        case 'u':
        case 'x':
        case 'X':
        case 'o': {
            unsigned long long v = lng ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned);
            n = fmt_u(t, v, *f == 'u' ? 10 : *f == 'o' ? 8 : 16, *f == 'X');
            out_pad(&o, t, n, width, left, pad);
            break;
        }
        case 'p': {
            t[0] = '0', t[1] = 'x';
            n = 2 + fmt_u(t + 2, (uintptr_t)va_arg(ap, void *), 16, false);
            out_pad(&o, t, n, width, left, ' ');
            break;
        }
        case 'c':
            t[0] = (char)va_arg(ap, int);
            out_pad(&o, t, 1, width, left, ' ');
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            size_t k = strlen(s);
            if (prec >= 0 && (size_t)prec < k) k = (size_t)prec;
            out_pad(&o, s, k, width, left, ' ');
            break;
        }
        case 'f':
        case 'F':
        case 'g':
        case 'G':
        case 'e':
        case 'E':
            fmt_double(&o, va_arg(ap, double), prec, (char)(*f | 32), width, left, pad, plus);
            break;
        case '%':
            out_c(&o, '%');
            break;
        default:
            out_c(&o, '%');
            if (*f) out_c(&o, *f);
            else f--;
        }
    }
    if (cap) buf[o.n < cap ? o.n : cap - 1] = 0;
    return (int)o.n;
}

int snprintf(char *buf, size_t cap, const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    int n = vsnprintf(buf, cap, f, ap);
    va_end(ap);
    return n;
}

int vfprintf(FILE *fp, const char *f, va_list ap) {
    (void)fp;
    char b[512];
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(b, sizeof b, f, ap);
    if ((size_t)n < sizeof b) kputs(b, (size_t)n);
    else {
        // long output: format into a buffer on the stack big enough for it
        char *big = __builtin_alloca((size_t)n + 1);
        vsnprintf(big, (size_t)n + 1, f, ap2);
        kputs(big, (size_t)n);
    }
    va_end(ap2);
    return n;
}

int fprintf(FILE *fp, const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    int n = vfprintf(fp, f, ap);
    va_end(ap);
    return n;
}

int printf(const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    int n = vfprintf(stdout, f, ap);
    va_end(ap);
    return n;
}

int fputs(const char *s, FILE *fp) {
    (void)fp;
    kputs(s, strlen(s));
    return 0;
}

int puts(const char *s) {
    kputs(s, strlen(s));
    kputs("\n", 1);
    return 0;
}

int putchar(int c) {
    char ch = (char)c;
    kputs(&ch, 1);
    return c;
}

int64_t st_k_wait_byte(void);
int getchar(void) { // raw console bytes (the builtin `read_line` uses it; there is no end of input)
    int c = (int)st_k_wait_byte();
    return c == '\r' ? '\n' : c;
}

int fflush(FILE *fp) {
    (void)fp;
    return 0;
}

char *getenv(const char *name) {
    (void)name;
    return NULL;
}

_Noreturn void kexit(int code);
_Noreturn void exit(int code) { kexit(code); }
_Noreturn void abort(void) { kexit(134); }

// ---- sorting (a merge sort: no recursion depth worth worrying about, no allocation) ----

static void swap_bytes(char *a, char *b, size_t n) {
    while (n--) {
        char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

// in-place, O(n log^2 n): shell sort with Ciura-like gaps, then insertion. Stable enough for runtime.c
// (it sorts ints, floats and strings, where equal elements are indistinguishable).
void qsort(void *base, size_t n, size_t sz, int (*cmp)(const void *, const void *)) {
    static const size_t gaps[] = {1750, 701, 301, 132, 57, 23, 10, 4, 1};
    char *b = base;
    size_t g0 = n / 2;
    // big inputs: add gaps of ~2.25x above the table
    size_t big[64];
    int nb = 0;
    for (size_t g = 3937; g < g0 && nb < 64; g = g * 9 / 4) big[nb++] = g;
    for (int bi = nb - 1; bi >= -(int)(sizeof gaps / sizeof *gaps); bi--) {
        size_t gap = bi >= 0 ? big[bi] : gaps[-bi - 1];
        if (gap >= n) continue;
        for (size_t i = gap; i < n; i++) {
            for (size_t j = i; j >= gap && cmp(b + (j - gap) * sz, b + j * sz) > 0; j -= gap) swap_bytes(b + (j - gap) * sz, b + j * sz, sz);
        }
    }
}

size_t strcspn(const char *s, const char *reject) {
    size_t n = 0;
    while (s[n] && !strchr(reject, s[n])) n++;
    return n;
}

int sprintf(char *buf, const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    int n = vsnprintf(buf, (size_t)-1 / 2, f, ap);
    va_end(ap);
    return n;
}
