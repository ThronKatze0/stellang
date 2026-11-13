// Graphics: a framebuffer driver for QEMU's `ramfb` display, and drawing on it. Written entirely in
// stellang on top of `kernel` (peek/poke for registers, alloc_pages for memory the display reads).
//
// ramfb is configured through QEMU's fw_cfg device: find the file "etc/ramfb" in fw_cfg's
// directory, then DMA a small config into it (where the pixels are, their format and size).
// After that, whatever is in that memory is on screen.

import kernel
import font

const FW_CFG = 0x1010_0000        // fw_cfg on QEMU virt (riscv64)
const FW_DATA = FW_CFG
const FW_SELECT = FW_CFG + 8
const FW_DMA = FW_CFG + 16
const XRGB8888 = 0x3432_5258      // DRM fourcc "XR24": 32-bit pixels, 0x00RRGGBB

// big-endian, as fw_cfg wants
fn put_be(addr: int, bytes: int, v: int) {
    for i in 0..bytes {
        kernel.poke8(addr + i, (v >> ((bytes - 1 - i) * 8)) & 0xff)
    }
}

fn bswap32(v: int) -> int {
    return ((v & 0xff) << 24) | ((v >> 8 & 0xff) << 16) | ((v >> 16 & 0xff) << 8) | (v >> 24 & 0xff)
}

fn fw_select(key: int) {
    kernel.poke16(FW_SELECT, ((key & 0xff) << 8) | (key >> 8 & 0xff))
}

fn fw_read(n: int) -> int {
    var v = 0
    for i in 0..n { v = (v << 8) | kernel.peek8(FW_DATA) }
    return v
}

// The fw_cfg selector of a file, by name ("etc/ramfb"), if QEMU has it.
fn fw_file(name: str) -> int? {
    fw_select(0)
    if fw_read(4) != 0x5145_4d55 { return none } // "QEMU"
    fw_select(0x19)
    let count = fw_read(4)
    for i in 0..count {
        fw_read(4)                      // size
        let sel = fw_read(2)
        fw_read(2)
        var chars: [str] = []
        for k in 0..56 {
            let c = fw_read(1)
            if c != 0 { chars.push(st_chr(c)) }
        }
        if chars.join("") == name { return some(sel) }
    }
    return none
}

extern fn st_chr(code: int) -> str

// Write `len` bytes at `src` into fw_cfg file `sel` by DMA. Returns false on an error.
fn fw_dma_write(sel: int, src: int, len: int) -> bool {
    let access = kernel.alloc_pages(1)
    put_be(access, 4, (sel << 16) | 0x08 | 0x10)   // select + write
    put_be(access + 4, 4, len)
    put_be(access + 8, 8, src)
    kernel.poke32(FW_DMA, bswap32(access >> 32))   // the register is big-endian: high half first,
    kernel.poke32(FW_DMA + 4, bswap32(access & 0xffff_ffff)) // writing the low half starts it
    while true {
        let ctl = fw_read_be32(access)
        if ctl & 1 != 0 { return false }
        if ctl == 0 { return true }
    }
    return false
}

fn fw_read_be32(addr: int) -> int {
    var v = 0
    for i in 0..4 { v = (v << 8) | kernel.peek8(addr + i) }
    return v
}

struct Screen {
    width: int,
    height: int,
    base: int,                    // the pixels: width * height * 4 bytes, row by row

    fn pixel(self, x: int, y: int, color: int) {
        if x >= 0 && y >= 0 && x < self.width && y < self.height {
            kernel.poke32(self.base + (y * self.width + x) * 4, color)
        }
    }

    fn rect(self, x: int, y: int, w: int, h: int, color: int) {
        let x0 = max(x, 0)
        let x1 = min(x + w, self.width)
        if x1 <= x0 { return }
        for row in max(y, 0)..min(y + h, self.height) {
            kernel.fill32(self.base + (row * self.width + x0) * 4, x1 - x0, color)
        }
    }

    fn frame(self, x: int, y: int, w: int, h: int, color: int) {
        self.rect(x, y, w, 1, color)
        self.rect(x, y + h - 1, w, 1, color)
        self.rect(x, y, 1, h, color)
        self.rect(x + w - 1, y, 1, h, color)
    }

    // text in the 5x7 font, each font pixel `scale` screen pixels; returns the width drawn
    fn text(self, x: int, y: int, s: str, color: int, scale: int) -> int {
        var cx = x
        for ch in s.upper().chars() {
            let i = font.GLYPHS.find(ch)
            if i >= 0 {
                let bits = font.FONT[i]
                for row in 0..7 {
                    for col in 0..5 {
                        if (bits >> (34 - row * 5 - col)) & 1 == 1 {
                            self.rect(cx + col * scale, y + row * scale, scale, scale, color)
                        }
                    }
                }
            }
            cx += 6 * scale
        }
        return cx - x
    }

    // a vertical gradient between two colors
    fn gradient(self, top: int, bottom: int) {
        for row in 0..self.height {
            self.rect(0, row, self.width, 1, mix(top, bottom, row, self.height))
        }
    }
}

// color a + (b - a) * k / n, per channel
fn mix(a: int, b: int, k: int, n: int) -> int {
    var out = 0
    for shift in [16, 8, 0] {
        let ca = a >> shift & 0xff
        let cb = b >> shift & 0xff
        out = out | ((ca + (cb - ca) * k / n) << shift)
    }
    return out
}

// Turn the display on at `width` x `height`. Fails if QEMU has no ramfb (`stellang boot --gui`).
fn open(width: int, height: int) -> Screen! {
    let sel = fw_file("etc/ramfb") ?? 0
    if sel == 0 { return err("no display (start QEMU with a ramfb: `stellang boot --gui os.st`)") }
    let base = kernel.alloc_pages((width * height * 4 + 4095) / 4096)
    let cfg = kernel.alloc_pages(1)
    put_be(cfg, 8, base)
    put_be(cfg + 8, 4, XRGB8888)
    put_be(cfg + 12, 4, 0)
    put_be(cfg + 16, 4, width)
    put_be(cfg + 20, 4, height)
    put_be(cfg + 24, 4, width * 4)
    if !fw_dma_write(sel, cfg, 28) { return err("the display didn't accept its configuration") }
    return Screen { width, height, base }
}
