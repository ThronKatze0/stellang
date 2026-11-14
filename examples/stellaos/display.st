// The display, written in stellang on top of `kernel` (peek/poke for registers, alloc_pages for
// memory the display reads). Drawing on it is std/gfx.st.
//
// On RISC-V (QEMU virt) it is QEMU's `ramfb`; on an x86 PC, the framebuffer the firmware (UEFI GOP)
// left on: the laptop's own panel at its own resolution. The desktop draws into a picture of its own
// (wm.st's back buffer) and `Screen.show` copies the parts that changed onto the real screen: there
// the rows can be longer than the picture (stride), red and blue can be the other way round, and on a
// high-resolution panel every pixel becomes 2x2 (or 3x3), so text stays readable.
//
// ramfb is configured through QEMU's fw_cfg device: find the file "etc/ramfb" in fw_cfg's
// directory, then DMA a small config into it (where the pixels are, their format and size).
// After that, whatever is in that memory is on screen.

import kernel
import gfx

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

extern fn st_k_fb(what: int) -> int

// The real screen, and how the desktop's picture goes onto it.
struct Screen {
    fb: gfx.Surface,          // the screen's memory (its width: the stride)
    width: int,               // the desktop's size, in its own pixels
    height: int,
    scale: int = 1,           // each desktop pixel is scale x scale on the screen
    left: int = 0,            // where the desktop starts on the screen (centered)
    top: int = 0,
    swap: bool = false,       // the screen wants red and blue swapped
    panel_w: int = 0,         // the screen's own size
    panel_h: int = 0,

    // Copy the rectangle (x, y, w, h) of `src` (the desktop's picture) onto the screen.
    fn show(self, src: gfx.Surface, x: int, y: int, w: int, h: int) {
        let mode = if self.swap { gfx.SWAP_RB } else { gfx.COPY }
        self.fb.blit(src, x, y, w, h, self.left + x * self.scale, self.top + y * self.scale, mode, 0, self.scale)
    }
}

// The firmware's screen (x86): [width, height, stride, format], or none.
fn panel() -> [int]? {
    if kernel.arch() != "x86_64" || st_k_fb(0) == 0 { return none }
    let fmt = st_k_fb(4)
    if fmt > 1 { return none }    // pixels laid out some other way: not something we draw on
    return some([st_k_fb(1), st_k_fb(2), st_k_fb(3), fmt])
}

// How much a panel of `w` x `h` is scaled up: the most that still leaves at least 1024 x 720
// desktop pixels (a 2560 x 1600 laptop panel: 2, a desktop of 1280 x 800).
fn scale_for(w: int, h: int) -> int {
    var s = 1
    while w / (s + 1) >= 1024 && h / (s + 1) >= 720 { s += 1 }
    return s
}

// The size the desktop should be on this machine: on a PC, the panel's (scaled down on high-
// resolution panels), on QEMU's RISC-V machine 1024 x 768.
fn size() -> [int] {
    if let p = panel() {
        let s = scale_for(p[0], p[1])
        return [p[0] / s, p[1] / s]
    }
    return [1024, 768]
}

// Turn the display on for a desktop of `width` x `height`. Fails if there is none (on RISC-V:
// QEMU has no ramfb, `stellang boot --gui`).
fn open(width: int, height: int) -> Screen! {
    if kernel.arch() == "x86_64" {
        let p = panel() ?? []
        if p.is_empty() { return err("no display (the firmware gave us no framebuffer we can draw on)") }
        let pw = p[0]
        let ph = p[1]
        var s = scale_for(pw, ph)
        while s > 1 && (width * s > pw || height * s > ph) { s -= 1 }
        if width > pw || height > ph { return err("the screen is ${pw}x${ph}, smaller than ${width}x${height}") }
        let fb = gfx.wrap(st_k_fb(0), p[2], ph)
        fb.clear(0)
        return Screen { fb, width, height, scale: s, left: (pw - width * s) / 2, top: (ph - height * s) / 2, swap: p[3] == 0,
            panel_w: pw, panel_h: ph }
    }
    return ramfb(width, height)
}

fn ramfb(width: int, height: int) -> Screen! {
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
    return Screen { fb: gfx.wrap(base, width, height), width, height, panel_w: width, panel_h: height }
}
