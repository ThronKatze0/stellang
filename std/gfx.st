// gfx: fast 2D drawing for --kernel programs (StellaOS's windows, apps and games).
//
//     import gfx
//
//     let s = gfx.surface(320, 200)            // an image in memory: 32-bit 0xRRGGBB pixels
//     s.clear(0x101820)
//     s.round(10, 10, 120, 40, 8, 0x6c5ce7)    // a rounded rectangle
//     s.text(22, 22, "Hello", 0xffffff, gfx.UI_BOLD)
//     s.circle(200, 100, 30, 0xfdcb6e)
//     screen.draw(s, 0, 0)                      // copy it onto another surface
//
// The drawing itself is native code (src/runtime_kernel.c); text is anti-aliased Inter and DejaVu
// Sans Mono (Latin-1 plus a few symbols: ✦ ★ • … ← ↑ → ↓ ✓ ✕ ● ■ ▲ ▶ ♥). A surface's pixels live on
// the garbage-collected heap and go away with the last Surface that holds them.

extern fn st_k_alloc(bytes: int) -> int
extern fn st_k_poke(addr: int, size: int, value: int)
extern fn st_g_target(base: int, w: int, h: int)
extern fn st_g_clip(x: int, y: int, w: int, h: int)
extern fn st_g_fill(x: int, y: int, w: int, h: int, color: int)
extern fn st_g_blend(x: int, y: int, w: int, h: int, color: int, alpha: int)
extern fn st_g_round(x: int, y: int, w: int, h: int, r: int, color: int, alpha: int)
extern fn st_g_circle(cx: int, cy: int, r: int, color: int, alpha: int)
extern fn st_g_line(x0: int, y0: int, x1: int, y1: int, width: int, color: int)
extern fn st_g_pixel(x: int, y: int, color: int)
extern fn st_g_get(x: int, y: int) -> int
extern fn st_g_blit(src: int, sw: int, sh: int, sx: int, sy: int, w: int, h: int, dx: int, dy: int, mode: int, key: int, scale: int)
extern fn st_g_text(x: int, y: int, s: str, color: int, face: int) -> int
extern fn st_g_text_width(s: str, face: int) -> int
extern fn st_g_font(face: int, what: int) -> int

// Faces: sizes and weights of text.
const UI = 0          // Inter 13 px: labels, menus, buttons
const UI_BOLD = 1
const TEXT = 2        // Inter 16 px
const TEXT_BOLD = 3
const TITLE = 4       // Inter Bold 22 px
const MONO = 5        // DejaVu Sans Mono 13 px: terminals, code
const MONO_BOLD = 6
const BIG = 7         // Inter Bold 34 px: scores, splash screens

// Copy modes for `Surface.blit`
const COPY = 0
const ALPHA = 1       // the source's top byte is its opacity (0xAARRGGBB)
const KEYED = 2       // pixels of one color are see-through

struct Surface {
    width: int,
    height: int,
    base: int,                // address of the first pixel; rows follow each other
    clip_x: int = 0,
    clip_y: int = 0,
    clip_w: int = -1,         // -1: no clipping beyond the edges
    clip_h: int = 0,

    // make this the surface the native code draws on
    fn bind(self) {
        st_g_target(self.base, self.width, self.height)
        if self.clip_w >= 0 { st_g_clip(self.clip_x, self.clip_y, self.clip_w, self.clip_h) }
    }

    // Draw only inside this rectangle from now on (`unclip` lifts it).
    fn clip(self, x: int, y: int, w: int, h: int) {
        self.clip_x = x
        self.clip_y = y
        self.clip_w = max(w, 0)
        self.clip_h = max(h, 0)
    }

    fn unclip(self) {
        self.clip_w = -1
    }

    fn clear(self, color: int) {
        self.bind()
        st_g_fill(0, 0, self.width, self.height, color)
    }

    fn rect(self, x: int, y: int, w: int, h: int, color: int) {
        self.bind()
        st_g_fill(x, y, w, h, color)
    }

    // a rectangle that lets what's under it show through (alpha 0..255)
    fn shade(self, x: int, y: int, w: int, h: int, color: int, alpha: int) {
        self.bind()
        st_g_blend(x, y, w, h, color, alpha)
    }

    // a one-pixel outline
    fn frame(self, x: int, y: int, w: int, h: int, color: int) {
        self.bind()
        st_g_fill(x, y, w, 1, color)
        st_g_fill(x, y + h - 1, w, 1, color)
        st_g_fill(x, y, 1, h, color)
        st_g_fill(x + w - 1, y, 1, h, color)
    }

    fn round(self, x: int, y: int, w: int, h: int, r: int, color: int) {
        self.bind()
        st_g_round(x, y, w, h, r, color, 255)
    }

    fn round_shade(self, x: int, y: int, w: int, h: int, r: int, color: int, alpha: int) {
        self.bind()
        st_g_round(x, y, w, h, r, color, alpha)
    }

    fn circle(self, cx: int, cy: int, r: int, color: int) {
        self.bind()
        st_g_circle(cx, cy, r, color, 255)
    }

    fn circle_shade(self, cx: int, cy: int, r: int, color: int, alpha: int) {
        self.bind()
        st_g_circle(cx, cy, r, color, alpha)
    }

    fn line(self, x0: int, y0: int, x1: int, y1: int, color: int) {
        self.bind()
        st_g_line(x0, y0, x1, y1, 1, color)
    }

    fn thick_line(self, x0: int, y0: int, x1: int, y1: int, width: int, color: int) {
        self.bind()
        st_g_line(x0, y0, x1, y1, width, color)
    }

    fn pixel(self, x: int, y: int, color: int) {
        self.bind()
        st_g_pixel(x, y, color)
    }

    fn get(self, x: int, y: int) -> int {
        self.bind()
        return st_g_get(x, y)
    }

    // Text with its line's top at y; returns how wide it was.
    fn text(self, x: int, y: int, s: str, color: int, face: int) -> int {
        self.bind()
        return st_g_text(x, y, s, color, face)
    }

    // Text centered in a box.
    fn text_in(self, x: int, y: int, w: int, h: int, s: str, color: int, face: int) {
        let tw = text_width(s, face)
        self.text(x + (w - tw) / 2, y + (h - line_height(face)) / 2, s, color, face)
    }

    // All of `src` with its top left at (x, y).
    fn draw(self, src: Surface, x: int, y: int) {
        self.bind()
        st_g_blit(src.base, src.width, src.height, 0, 0, src.width, src.height, x, y, COPY, 0, 1)
    }

    // `src` blended by its alpha bytes, each pixel `scale` x `scale` (sprites, pixel art).
    fn sprite(self, src: Surface, x: int, y: int, scale: int) {
        self.bind()
        st_g_blit(src.base, src.width, src.height, 0, 0, src.width, src.height, x, y, ALPHA, 0, scale)
    }

    // The general copy: a part of `src`, a mode (COPY, ALPHA, KEYED with `key`), a whole-pixel scale.
    fn blit(self, src: Surface, sx: int, sy: int, w: int, h: int, dx: int, dy: int, mode: int, key: int, scale: int) {
        self.bind()
        st_g_blit(src.base, src.width, src.height, sx, sy, w, h, dx, dy, mode, key, scale)
    }

    // A vertical gradient over a rectangle.
    fn gradient(self, x: int, y: int, w: int, h: int, top: int, bottom: int) {
        self.bind()
        for row in 0..h {
            st_g_fill(x, y + row, w, 1, mix(top, bottom, row, max(h - 1, 1)))
        }
    }
}

// A new surface, filled with black.
fn surface(width: int, height: int) -> Surface {
    return Surface { width, height, base: st_k_alloc(width * height * 4) }
}

// A surface over memory you already have (a framebuffer).
fn wrap(base: int, width: int, height: int) -> Surface {
    return Surface { width, height, base }
}

// A sprite from rows of characters: each character is a pixel, its color from `palette`
// ("." and " " are see-through). sprite([".#.", "###"], {"#": 0xff0000})
fn sprite(rows: [str], palette: {str: int}) -> Surface {
    var w = 0
    for r in rows { w = max(w, r.chars().len()) }
    let s = surface(w, rows.len())
    for y, r in rows {
        for x, c in r.chars() {
            if let color = palette.get(c) {
                // the alpha byte: solid
                st_k_poke(s.base + (y * w + x) * 4, 4, color | (255 << 24))
            }
        }
    }
    return s
}

fn text_width(s: str, face: int) -> int {
    return st_g_text_width(s, face)
}

fn line_height(face: int) -> int {
    return st_g_font(face, 2)
}

fn ascent(face: int) -> int {
    return st_g_font(face, 0)
}

fn rgb(r: int, g: int, b: int) -> int {
    return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
}

fn clamp(v: int) -> int {
    return min(max(v, 0), 255)
}

// The color k/n of the way from a to b.
fn mix(a: int, b: int, k: int, n: int) -> int {
    var out = 0
    for shift in [16, 8, 0] {
        let ca = a >> shift & 0xff
        let cb = b >> shift & 0xff
        out = out | ((ca + (cb - ca) * k / n) << shift)
    }
    return out
}

// Lighter (amount > 0) or darker (< 0), amount in -255..255.
fn tint(c: int, amount: int) -> int {
    if amount >= 0 { return mix(c, 0xffffff, amount, 255) }
    return mix(c, 0, -amount, 255)
}
