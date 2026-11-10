// wasm64 stand-ins for the C library calls Dear ImGui 1.89.6 imports.
// The Jai web link is wasm-ld plus walloc, so emscripten's libc (and its JS
// syscalls) is not on the link line. Compile with:
//   emcc -c -O2 -sMEMORY64=1 -fno-builtin -fno-exceptions assets/wasm_libc.c -o assets/wasm_libc.o

typedef unsigned long long u64;
typedef long long s64;
typedef unsigned int u32;
typedef int s32;
typedef unsigned char u8;

typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_end(ap) __builtin_va_end(ap)
#define va_arg(ap, type) __builtin_va_arg(ap, type)

static double trunc_d(double x) {
    if (x >= 9223372036854775808.0 || x <= -9223372036854775808.0) return x;
    return (double)(s64)x;
}

static double ln(double x) {
    union { double d; u64 u; } bits;
    s32 exp;
    double m, z, z2, s, term;
    s32 i;
    if (x < 0) return 0.0 / 0.0;
    if (x == 0) return -1.0 / 0.0;
    bits.d = x;
    exp = (s32)((bits.u >> 52) & 0x7ff) - 1023;
    bits.u = (bits.u & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL;
    m = bits.d;
    z = (m - 1.0) / (m + 1.0);
    z2 = z * z;
    s = z;
    term = z;
    for (i = 1; i < 24; i++) {
        term *= z2;
        s += term / (double)(2 * i + 1);
    }
    return 2.0 * s + (double)exp * 0.693147180559945309417;
}

static double expd(double x) {
    union { double d; u64 u; } bits;
    double ln2, r, s, term;
    s32 n, i, e;
    if (x > 700) return 1.0 / 0.0;
    if (x < -745) return 0;
    ln2 = 0.693147180559945309417;
    n = (s32)(x / ln2 + (x >= 0 ? 0.5 : -0.5));
    r = x - (double)n * ln2;
    s = 1;
    term = 1;
    for (i = 1; i < 30; i++) {
        term *= r / (double)i;
        s += term;
    }
    bits.d = s;
    e = (s32)((bits.u >> 52) & 0x7ff) + n;
    if (e <= 0) return 0;
    if (e >= 2047) return 1.0 / 0.0;
    bits.u = (bits.u & ~(0x7ffULL << 52)) | ((u64)e << 52);
    return bits.d;
}

double log(double x) { return ln(x); }

double pow(double x, double y) {
    double ay;
    s64 n;
    double r;
    if (y == 0) return 1;
    if (x == 0) return y > 0 ? 0 : 1.0 / 0.0;
    if (x < 0) {
        ay = y < 0 ? -y : y;
        if (ay >= 9223372036854775808.0) return 0.0 / 0.0;
        n = (s64)trunc_d(y);
        if ((double)n != y) return 0.0 / 0.0;
        r = expd((double)n * ln(-x));
        if (n & 1) r = -r;
        return r;
    }
    return expd(y * ln(x));
}

float logf(float x) { return (float)ln((double)x); }
float powf(float x, float y) { return (float)pow((double)x, (double)y); }

float fmodf(float x, float y) {
    double q;
    if (y == 0) return 0.0f / 0.0f;
    q = trunc_d((double)x / (double)y);
    return (float)((double)x - (double)y * q);
}

static double sind(double x) {
    double pi, two_pi, x2, s, term;
    s32 i;
    pi = 3.14159265358979323846;
    two_pi = 2.0 * pi;
    x = x - two_pi * trunc_d(x / two_pi);
    if (x > pi) x -= two_pi;
    if (x < -pi) x += two_pi;
    x2 = x * x;
    s = x;
    term = x;
    for (i = 1; i < 14; i++) {
        term *= -x2 / (double)((2 * i) * (2 * i + 1));
        s += term;
    }
    return s;
}

static double cosd(double x) {
    return sind(x + 1.57079632679489661923);
}

float sinf(float x) { return (float)sind((double)x); }
float cosf(float x) { return (float)cosd((double)x); }

static double atand(double x) {
    int neg, inv;
    double x2, a;
    neg = x < 0;
    if (neg) x = -x;
    inv = x > 1.0;
    if (inv) x = 1.0 / x;
    x2 = x * x;
    a = x * (1.0 + x2 * (-0.3333333333 + x2 * (0.2 + x2 * (-0.1428571429 + x2 * (0.1111111111 + x2 * -0.0909090909)))));
    if (inv) a = 1.57079632679489661923 - a;
    return neg ? -a : a;
}

float acosf(float x) {
    double xx, y;
    if (x <= -1.0f) return 3.14159265f;
    if (x >= 1.0f) return 0;
    xx = (double)x;
    y = __builtin_sqrt(1.0 - xx * xx);
    if (xx > 0) return (float)atand(y / xx);
    if (xx < 0) return (float)(3.14159265358979323846 + atand(y / xx));
    return 1.5707963f;
}

u64 strlen(const char *s) {
    u64 n = 0;
    if (!s) return 0;
    while (s[n]) n++;
    return n;
}

s32 strcmp(const char *a, const char *b) {
    u8 ca, cb;
    if (!a || !b) return (s32)(a != b);
    for (;;) {
        ca = (u8)*a++;
        cb = (u8)*b++;
        if (ca != cb || ca == 0) return (s32)ca - (s32)cb;
    }
}

s32 strncmp(const char *a, const char *b, u64 n) {
    u8 ca, cb;
    if (!a || !b) return (s32)(a != b);
    while (n--) {
        ca = (u8)*a++;
        cb = (u8)*b++;
        if (ca != cb || ca == 0) return (s32)ca - (s32)cb;
    }
    return 0;
}

char *strncpy(char *dst, const char *src, u64 n) {
    u64 i = 0;
    if (!dst) return dst;
    if (src) {
        while (i < n && src[i]) {
            dst[i] = src[i];
            i++;
        }
    }
    while (i < n) dst[i++] = 0;
    return dst;
}

s32 memcmp(const void *av, const void *bv, u64 n) {
    const u8 *a = (const u8 *)av;
    const u8 *b = (const u8 *)bv;
    while (n--) {
        if (*a != *b) return (s32)*a - (s32)*b;
        a++;
        b++;
    }
    return 0;
}

void *memchr(const void *av, s32 c, u64 n) {
    const u8 *a = (const u8 *)av;
    u8 k = (u8)c;
    while (n--) {
        if (*a == k) return (void *)a;
        a++;
    }
    return 0;
}

char *strstr(const char *hay, const char *needle) {
    u64 nlen, i;
    if (!hay || !needle) return 0;
    nlen = strlen(needle);
    if (nlen == 0) return (char *)hay;
    for (; *hay; hay++) {
        for (i = 0; i < nlen; i++) {
            if (hay[i] != needle[i]) break;
        }
        if (i == nlen) return (char *)hay;
    }
    return 0;
}

static void memswap(u8 *a, u8 *b, u64 n) {
    u8 t;
    while (n--) {
        t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

void qsort(void *base, u64 nmemb, u64 size, s32 (*compar)(const void *, const void *)) {
    u8 *b = (u8 *)base;
    s64 i, j, n, parent, child;
    if (!b || !compar || nmemb < 2 || size == 0) return;
    n = (s64)nmemb;
    for (i = n / 2 - 1; i >= 0; i--) {
        parent = i;
        for (;;) {
            child = parent * 2 + 1;
            if (child >= n) break;
            if (child + 1 < n && compar(b + (u64)(child + 1) * size, b + (u64)child * size) > 0) child++;
            if (compar(b + (u64)parent * size, b + (u64)child * size) >= 0) break;
            memswap(b + (u64)parent * size, b + (u64)child * size, size);
            parent = child;
        }
    }
    for (j = n - 1; j > 0; j--) {
        memswap(b, b + (u64)j * size, size);
        parent = 0;
        for (;;) {
            child = parent * 2 + 1;
            if (child >= j) break;
            if (child + 1 < j && compar(b + (u64)(child + 1) * size, b + (u64)child * size) > 0) child++;
            if (compar(b + (u64)parent * size, b + (u64)child * size) >= 0) break;
            memswap(b + (u64)parent * size, b + (u64)child * size, size);
            parent = child;
        }
    }
}

double atof(const char *s) {
    double sign, val, frac, base;
    s32 exp_sign, exp, any;
    if (!s) return 0;
    while (*s == ' ' || *s == '\t') s++;
    sign = 1;
    if (*s == '+') s++;
    else if (*s == '-') { sign = -1; s++; }
    val = 0;
    any = 0;
    while (*s >= '0' && *s <= '9') {
        val = val * 10.0 + (double)(*s - '0');
        s++;
        any = 1;
    }
    if (*s == '.') {
        s++;
        frac = 0;
        base = 0.1;
        while (*s >= '0' && *s <= '9') {
            frac += (double)(*s - '0') * base;
            base *= 0.1;
            s++;
            any = 1;
        }
        val += frac;
    }
    if (*s == 'e' || *s == 'E') {
        s++;
        exp_sign = 1;
        if (*s == '+') s++;
        else if (*s == '-') { exp_sign = -1; s++; }
        exp = 0;
        while (*s >= '0' && *s <= '9') {
            exp = exp * 10 + (*s - '0');
            s++;
        }
        val *= pow(10.0, (double)(exp_sign * exp));
    }
    if (!any) return 0;
    return sign * val;
}

typedef struct Out {
    char *buf;
    u64 size;
    u64 count;
} Out;

static void out_ch(Out *o, char c) {
    if (o->buf && o->size > 0 && o->count + 1 < o->size) o->buf[o->count] = c;
    o->count++;
}

static void out_str(Out *o, const char *s, s32 width, s32 prec, s32 left, s32 pad_zero) {
    s32 len, i, pad;
    if (!s) s = "(null)";
    len = 0;
    while (s[len] && (prec < 0 || len < prec)) len++;
    pad = width > len ? width - len : 0;
    if (!left && !pad_zero) for (i = 0; i < pad; i++) out_ch(o, ' ');
    if (!left && pad_zero) for (i = 0; i < pad; i++) out_ch(o, '0');
    for (i = 0; i < len; i++) out_ch(o, s[i]);
    if (left) for (i = 0; i < pad; i++) out_ch(o, ' ');
}

static void out_u(Out *o, u64 v, s32 base, s32 upper, s32 width, s32 prec, s32 left, s32 pad_zero, s32 prefix) {
    char tmp[72];
    s32 n = 0, i, pad, digits;
    const char *digits_l = "0123456789abcdef";
    const char *digits_u = "0123456789ABCDEF";
    const char *dig = upper ? digits_u : digits_l;
    if (v == 0) tmp[n++] = '0';
    while (v) {
        tmp[n++] = dig[v % (u64)base];
        v /= (u64)base;
    }
    digits = n;
    if (prec > digits) digits = prec;
    pad = width - digits - (prefix ? 2 : 0);
    if (pad < 0) pad = 0;
    if (!left && !pad_zero) for (i = 0; i < pad; i++) out_ch(o, ' ');
    if (prefix) {
        out_ch(o, '0');
        out_ch(o, upper ? 'X' : 'x');
    }
    if (!left && pad_zero) for (i = 0; i < pad; i++) out_ch(o, '0');
    for (i = 0; i < prec - n; i++) out_ch(o, '0');
    while (n--) out_ch(o, tmp[n]);
    if (left) for (i = 0; i < pad; i++) out_ch(o, ' ');
}

static void out_f(Out *o, double v, s32 width, s32 prec, s32 left, s32 pad_zero, s32 plus, s32 space, s32 trim) {
    char tmp[128];
    s32 n = 0, i, neg, ip, pad;
    u64 whole, frac, scale;
    double ipart;
    if (prec < 0) prec = 6;
    if (prec > 12) prec = 12;
    neg = v < 0 || (v == 0 && 1.0 / v < 0);
    if (neg) v = -v;
    scale = 1;
    for (i = 0; i < prec; i++) scale *= 10;
    v += 0.5 / (double)scale;
    ipart = trunc_d(v);
    whole = (u64)ipart;
    frac = (u64)((v - ipart) * (double)scale);
    if (frac >= scale) {
        whole++;
        frac -= scale;
    }
    if (whole == 0) tmp[n++] = '0';
    while (whole) {
        tmp[n++] = (char)('0' + (whole % 10));
        whole /= 10;
    }
    ip = n;
    if (neg) out_ch(o, '-');
    else if (plus) out_ch(o, '+');
    else if (space) out_ch(o, ' ');
    pad = width - (neg || plus || space ? 1 : 0) - ip - (prec > 0 && !trim ? prec + 1 : 0);
    if (pad < 0) pad = 0;
    if (!left && pad_zero) for (i = 0; i < pad; i++) out_ch(o, '0');
    else if (!left) for (i = 0; i < pad; i++) out_ch(o, ' ');
    while (ip--) out_ch(o, tmp[ip]);
    if (prec > 0) {
        char fbuf[16];
        s32 fn = 0;
        u64 f = frac;
        for (i = 0; i < prec; i++) {
            fbuf[fn++] = (char)('0' + (f % 10));
            f /= 10;
        }
        if (trim) {
            while (fn > 0 && fbuf[0] == '0') {
                for (i = 0; i < fn - 1; i++) fbuf[i] = fbuf[i + 1];
                fn--;
            }
        }
        if (fn > 0 || !trim) {
            out_ch(o, '.');
            while (fn--) out_ch(o, fbuf[fn]);
        }
    }
    if (left) for (i = 0; i < pad; i++) out_ch(o, ' ');
}

static s32 format_into(char *buf, u64 size, const char *fmt, va_list ap) {
    Out o;
    o.buf = buf;
    o.size = size;
    o.count = 0;
    if (!fmt) fmt = "";
    while (*fmt) {
        s32 left, plus, space, zero, hash, width, prec, have_prec;
        char spec;
        if (*fmt != '%') {
            out_ch(&o, *fmt++);
            continue;
        }
        fmt++;
        left = plus = space = zero = hash = 0;
        for (;;) {
            if (*fmt == '-') { left = 1; fmt++; }
            else if (*fmt == '+') { plus = 1; fmt++; }
            else if (*fmt == ' ') { space = 1; fmt++; }
            else if (*fmt == '0') { zero = 1; fmt++; }
            else if (*fmt == '#') { hash = 1; fmt++; }
            else break;
        }
        width = 0;
        if (*fmt == '*') {
            width = va_arg(ap, s32);
            fmt++;
            if (width < 0) { left = 1; width = -width; }
        } else {
            while (*fmt >= '0' && *fmt <= '9') {
                width = width * 10 + (*fmt - '0');
                fmt++;
            }
        }
        prec = -1;
        have_prec = 0;
        if (*fmt == '.') {
            fmt++;
            have_prec = 1;
            prec = 0;
            if (*fmt == '*') {
                prec = va_arg(ap, s32);
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9') {
                    prec = prec * 10 + (*fmt - '0');
                    fmt++;
                }
            }
        }
        if (*fmt == 'l') {
            fmt++;
            if (*fmt == 'l') fmt++;
        } else if (*fmt == 'h') {
            fmt++;
            if (*fmt == 'h') fmt++;
        } else if (*fmt == 'z' || *fmt == 't') {
            fmt++;
        }
        spec = *fmt ? *fmt++ : 0;
        if (spec == '%') {
            out_ch(&o, '%');
        } else if (spec == 'c') {
            char ch[2];
            ch[0] = (char)va_arg(ap, s32);
            ch[1] = 0;
            out_str(&o, ch, width, 1, left, 0);
        } else if (spec == 's') {
            out_str(&o, va_arg(ap, const char *), width, prec, left, 0);
        } else if (spec == 'd' || spec == 'i') {
            s64 v = va_arg(ap, s32);
            if (v < 0) {
                out_ch(&o, '-');
                out_u(&o, (u64)(-v), 10, 0, width > 0 ? width - 1 : 0, prec, left, zero, 0);
            } else {
                if (plus) out_ch(&o, '+');
                else if (space) out_ch(&o, ' ');
                out_u(&o, (u64)v, 10, 0, width - (plus || space ? 1 : 0), prec, left, zero, 0);
            }
        } else if (spec == 'u') {
            out_u(&o, (u64)va_arg(ap, u32), 10, 0, width, prec, left, zero, 0);
        } else if (spec == 'x' || spec == 'X') {
            out_u(&o, (u64)va_arg(ap, u32), 16, spec == 'X', width, prec, left, zero, hash);
        } else if (spec == 'p') {
            out_u(&o, (u64)va_arg(ap, void *), 16, 0, width, prec, left, zero, 1);
        } else if (spec == 'f' || spec == 'F') {
            out_f(&o, va_arg(ap, double), width, prec, left, zero, plus, space, 0);
        } else if (spec == 'g' || spec == 'G' || spec == 'e' || spec == 'E') {
            out_f(&o, va_arg(ap, double), width, have_prec ? prec : 6, left, zero, plus, space, spec == 'g' || spec == 'G');
        } else if (spec) {
            out_ch(&o, spec);
        }
        (void)hash;
    }
    if (buf && size > 0) {
        u64 end = o.count < size ? o.count : size - 1;
        buf[end] = 0;
    }
    return (s32)o.count;
}

int vsnprintf(char *buf, u64 size, const char *fmt, va_list ap) {
    return format_into(buf, size, fmt, ap);
}

int iprintf(const char *fmt, ...) {
    va_list ap;
    s32 n;
    va_start(ap, fmt);
    n = format_into(0, 0, fmt, ap);
    va_end(ap);
    return n;
}

static s32 is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

int sscanf(const char *str, const char *fmt, ...) {
    va_list ap;
    const char *start = str;
    s32 assigned = 0;
    if (!str || !fmt) return -1;
    va_start(ap, fmt);
    while (*fmt) {
        s32 width, suppress;
        if (is_space(*fmt)) {
            while (is_space(*fmt)) fmt++;
            while (is_space(*str)) str++;
            continue;
        }
        if (*fmt != '%') {
            if (*fmt++ != *str++) { va_end(ap); return assigned; }
            continue;
        }
        fmt++;
        suppress = 0;
        if (*fmt == '*') { suppress = 1; fmt++; }
        width = 0;
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        if (*fmt == 'l') fmt++;
        if (*fmt == 'd' || *fmt == 'i' || *fmt == 'u') {
            s32 sign = 1, digits = 0;
            u64 v = 0;
            char kind = *fmt++;
            while (is_space(*str)) str++;
            if (*str == '+') str++;
            else if (*str == '-') { sign = -1; str++; }
            if (kind == 'i' && str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) {
                str += 2;
                while ((*str >= '0' && *str <= '9') || (*str >= 'a' && *str <= 'f') || (*str >= 'A' && *str <= 'F')) {
                    u32 d = *str <= '9' ? (u32)(*str - '0') : (*str >= 'a' ? (u32)(*str - 'a' + 10) : (u32)(*str - 'A' + 10));
                    v = v * 16 + d;
                    str++;
                    digits++;
                    if (width && digits >= width) break;
                }
            } else {
                s32 base = 10;
                while (*str >= '0' && *str <= '9') {
                    v = v * (u64)base + (u64)(*str - '0');
                    str++;
                    digits++;
                    if (width && digits >= width) break;
                }
            }
            if (!digits) { va_end(ap); return assigned; }
            if (!suppress) {
                if (kind == 'u') *va_arg(ap, u32 *) = (u32)v;
                else *va_arg(ap, s32 *) = (s32)(sign < 0 ? -(s64)v : (s64)v);
                assigned++;
            }
        } else if (*fmt == 'x' || *fmt == 'X') {
            s32 digits = 0;
            u64 v = 0;
            fmt++;
            while (is_space(*str)) str++;
            if (str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) str += 2;
            while ((*str >= '0' && *str <= '9') || (*str >= 'a' && *str <= 'f') || (*str >= 'A' && *str <= 'F')) {
                u32 d = *str <= '9' ? (u32)(*str - '0') : (*str >= 'a' ? (u32)(*str - 'a' + 10) : (u32)(*str - 'A' + 10));
                v = v * 16 + d;
                str++;
                digits++;
                if (width && digits >= width) break;
            }
            if (!digits) { va_end(ap); return assigned; }
            if (!suppress) {
                *va_arg(ap, u32 *) = (u32)v;
                assigned++;
            }
        } else if (*fmt == 'f' || *fmt == 'g' || *fmt == 'e' || *fmt == 'F' || *fmt == 'G' || *fmt == 'E') {
            char tmp[64];
            s32 n = 0;
            fmt++;
            while (is_space(*str)) str++;
            if (*str == '+' || *str == '-') tmp[n++] = *str++;
            while (((*str >= '0' && *str <= '9') || *str == '.' || *str == 'e' || *str == 'E' || *str == '+' || *str == '-') && n < 63) {
                tmp[n++] = *str++;
                if (width && n >= width) break;
            }
            tmp[n] = 0;
            if (n == 0) { va_end(ap); return assigned; }
            if (!suppress) {
                *va_arg(ap, float *) = (float)atof(tmp);
                assigned++;
            }
        } else if (*fmt == 'c') {
            fmt++;
            if (!*str) { va_end(ap); return assigned; }
            if (!suppress) {
                *va_arg(ap, char *) = *str;
                assigned++;
            }
            str++;
        } else if (*fmt == 'n') {
            fmt++;
            if (!suppress) *va_arg(ap, s32 *) = (s32)(str - start);
        } else if (*fmt == '%') {
            fmt++;
            if (*str++ != '%') { va_end(ap); return assigned; }
        } else {
            va_end(ap);
            return assigned;
        }
    }
    va_end(ap);
    return assigned;
}

void __assert_fail(const char *expr, const char *file, s32 line, const char *func) {
    (void)expr;
    (void)file;
    (void)line;
    (void)func;
    __builtin_trap();
}

// C++ static destructors / atexit. No process teardown on wasm — accept and ignore.
int __cxa_atexit(void (*f)(void *), void *p, void *d) {
    (void)f;
    (void)p;
    (void)d;
    return 0;
}

int snprintf(char *buf, u64 size, const char *fmt, ...) {
    va_list ap;
    s32 n;
    va_start(ap, fmt);
    n = format_into(buf, size, fmt, ap);
    va_end(ap);
    return n;
}

// newlib integer / small sprintf variants pulled in by ImGui.a
int siprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    s32 n;
    va_start(ap, fmt);
    n = format_into(buf, (u64)0x7fffffff, fmt, ap);
    va_end(ap);
    return n;
}

int __small_sprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    s32 n;
    va_start(ap, fmt);
    n = format_into(buf, (u64)0x7fffffff, fmt, ap);
    va_end(ap);
    return n;
}

int toupper(int c) {
    if (c >= 'a' && c <= 'z') return c - ('a' - 'A');
    return c;
}

float atan2f(float y, float x) {
    double yy = (double)y;
    double xx = (double)x;
    double a;
    if (xx > 0) return (float)atand(yy / xx);
    if (xx < 0) {
        a = atand(yy / xx);
        return (float)(yy >= 0 ? a + 3.14159265358979323846 : a - 3.14159265358979323846);
    }
    if (yy > 0) return 1.5707963f;
    if (yy < 0) return -1.5707963f;
    return 0;
}
