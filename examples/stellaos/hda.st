// hda: Intel High Definition Audio, the sound hardware in nearly every PC, written in stellang:
// the controller (a DMA engine that plays from a looping buffer) and the codec on its link (the chip
// with the converters, mixers and the pins the speakers and headphone jack hang off).
//
// We talk to the codec one command at a time (the controller's "immediate command" registers),
// find the output pins (built-in speakers, headphones, line out), follow their connections back to a
// DAC, power it all on and unmute it, and point the DAC at the controller's first output stream:
// 48 kHz, 16-bit stereo, from a buffer we keep filled with what the synthesizer (sound.st) makes.
// Polled, like everything here.

import kernel
import pci
import sound

const RATE = 48000
const PERIOD = 960            // samples per period (20 ms)
const PERIODS = 4

struct Out {
    f: pci.Function,
    base: int,
    codec: int,
    dac: int,
    pins: [int],
    sd: int,                  // the output stream's registers
    buf: int,                 // PERIODS periods of stereo 16-bit samples
    bdl: int,
    filled: int = 0,          // periods written (ahead of the position)
    played: int = 0,
    tones: [sound.Tone] = [],
    kind: str = "Intel HD Audio",
    log: [str] = [],

    fn r32(self, off: int) -> int { return kernel.peek32(self.base + off) }
    fn w32(self, off: int, v: int) { kernel.poke32(self.base + off, v) }

    fn beep(self, hz: int, ms: int) {
        if self.tones.len() >= 8 { self.tones.remove(0) }
        let n = RATE * ms / 1000
        self.tones.push(sound.Tone { step: (hz << 32) / RATE, left: n, total: n })
    }

    // keep the periods ahead of the DMA position filled (silence when nothing plays)
    fn pump(self) {
        let pos = kernel.peek32(self.sd + 0x04)               // LPIB: bytes into the buffer
        let playing = pos / (PERIOD * 4)
        // fill every period but the one being played
        var k = 0
        while k < PERIODS - 1 {
            let p = (playing + 1 + k) % PERIODS
            if p == self.filled % PERIODS && self.filled - self.played < PERIODS {
                self.fill(p)
                self.filled += 1
            }
            k += 1
        }
        // how far it got
        while self.played % PERIODS != playing && self.played < self.filled { self.played += 1 }
    }

    fn fill(self, p: int) {
        let at = self.buf + p * PERIOD * 4
        if self.tones.is_empty() {
            kernel.fill32(at, PERIOD, 0)
            return
        }
        let mix = sound.render(self.tones, PERIOD, RATE)
        self.tones = self.tones.filter(t => t.left > 0)
        for i in 0..PERIOD {
            let v = mix[i] & 0xffff
            kernel.poke32(at + 4 * i, v | v << 16)
        }
    }
}

// one codec command (12-bit verbs: verb << 8 | payload; 4-bit ones: verb << 16 | payload): the
// response, or -1 if none came
fn cmd(base: int, codec: int, nid: int, verb: int) -> int {
    let until = now_ms() + 20
    while now_ms() < until && kernel.peek16(base + 0x68) & 1 != 0 {}     // ICB: busy
    kernel.poke32(base + 0x60, codec << 28 | nid << 20 | (verb & 0xfffff))
    kernel.poke16(base + 0x68, 2)                                          // clear IRV
    kernel.poke16(base + 0x68, 1)                                          // send
    let until2 = now_ms() + 20
    while now_ms() < until2 {
        let st = kernel.peek16(base + 0x68)
        if st & 1 == 0 && st & 2 != 0 { return kernel.peek32(base + 0x64) }
    }
    return -1
}

fn param(base: int, codec: int, nid: int, p: int) -> int { return cmd(base, codec, nid, 0xf0000 | p) }

// a widget's connections (node ids)
fn connections(base: int, codec: int, nid: int) -> [int] {
    var out: [int] = []
    let len = param(base, codec, nid, 0x0e)
    if len < 0 { return out }
    let n = len & 0x7f
    let long = len & 0x80 != 0
    var i = 0
    while i < n && i < 32 {
        let r = cmd(base, codec, nid, 0xf0200 | i)
        if r < 0 { break }
        let per = if long { 2 } else { 4 }
        for k in 0..per {
            if i + k >= n { break }
            let v = if long { (r >> (16 * k)) & 0xffff } else { (r >> (8 * k)) & 0xff }
            out.push(v & 0x7fff)
        }
        i += per
    }
    return out
}

fn kind_of(base: int, codec: int, nid: int) -> int { return (param(base, codec, nid, 0x09) >> 20) & 15 }

// from a widget, the way back to a DAC (audio output: kind 0): [widget, connection index, ...] or []
fn path_to_dac(base: int, codec: int, nid: int, depth: int) -> [int] {
    if depth > 6 { return [] }
    let cs = connections(base, codec, nid)
    for i, c in cs {
        let k = kind_of(base, codec, c)
        if k == 0 { return [nid, i, c] }
        if k == 2 || k == 3 {                                  // mixer, selector
            let rest = path_to_dac(base, codec, c, depth + 1)
            if !rest.is_empty() {
                var p = [nid, i]
                for x in rest { p.push(x) }
                return p
            }
        }
    }
    return []
}

fn unmute(base: int, codec: int, nid: int) {
    // output amp: both sides, unmuted, at its 0 dB step (or the top)
    let caps = param(base, codec, nid, 0x12)
    var gain = caps & 0x7f
    if gain == 0 { gain = (caps >> 8) & 0x7f }
    cmd(base, codec, nid, 0x3b000 | gain)
    // input amps (mixers): every input unmuted
    let icaps = param(base, codec, nid, 0x0d)
    let ig = icaps & 0x7f
    for i in 0..min(connections(base, codec, nid).len(), 16) { cmd(base, codec, nid, 0x37000 | (i << 8) | ig) }
}

fn open() -> Out? {
    for f in pci.all() {
        if f.class != 0x04 || f.subclass != 0x03 { continue }
        if let o = start(f) { return some(o) }
    }
    return none
}

fn start(f: pci.Function) -> Out? {
    f.wake()
    f.enable()
    let base = f.bar(0)
    if base == 0 { return none }
    // reset the controller and bring the link up
    kernel.poke32(base + 0x08, kernel.peek32(base + 0x08) & ~1)
    var until = now_ms() + 100
    while now_ms() < until && kernel.peek32(base + 0x08) & 1 != 0 {}
    sleep(1)
    kernel.poke32(base + 0x08, kernel.peek32(base + 0x08) | 1)
    until = now_ms() + 100
    while now_ms() < until && kernel.peek32(base + 0x08) & 1 == 0 {}
    sleep(5)                                                     // codecs announce themselves
    let present = kernel.peek16(base + 0x0e)
    let gcap = kernel.peek16(base)
    let iss = (gcap >> 8) & 15
    let oss = (gcap >> 12) & 15
    if oss == 0 { return none }
    for codec in 0..15 {
        if present & (1 << codec) == 0 { continue }
        // the audio function group
        let sub = param(base, codec, 0, 0x04)
        if sub < 0 { continue }
        var afg = -1
        for n in (sub >> 16) & 0xff..((sub >> 16) & 0xff) + (sub & 0xff) {
            if param(base, codec, n, 0x05) & 0xff == 1 { afg = n }
        }
        if afg < 0 { continue }
        cmd(base, codec, afg, 0x70500)                           // power: D0
        let ws = param(base, codec, afg, 0x04)
        let first = (ws >> 16) & 0xff
        // output pins with something on them: built-in speakers, headphones, line out
        var pins: [int] = []
        var dac = -1
        var paths: [[int]] = []
        for nid in first..first + (ws & 0xff) {
            if kind_of(base, codec, nid) != 4 { continue }
            if param(base, codec, nid, 0x0c) & 0x10 == 0 { continue }     // can't output
            let conf = cmd(base, codec, nid, 0xf1c00)
            let device = (conf >> 20) & 15
            let connected = (conf >> 30) & 3
            if connected == 1 || (device != 0 && device != 1 && device != 2) { continue }
            let p = path_to_dac(base, codec, nid, 0)
            if p.is_empty() { continue }
            pins.push(nid)
            paths.push(p)
            if dac < 0 { dac = p[p.len() - 1] }
        }
        if pins.is_empty() { continue }
        // the paths: powered, selected, unmuted; pins on (headphones with their amp), external amps on
        for k, p in paths {
            let pin = pins[k]
            let conf = cmd(base, codec, pin, 0xf1c00)
            let hp = ((conf >> 20) & 15) == 2
            cmd(base, codec, pin, 0x70700 | 0x40 | (if hp { 0x80 } else { 0 }))
            cmd(base, codec, pin, 0x70c02)                             // EAPD
            var i = 0
            while i + 1 < p.len() {
                let w = p[i]
                cmd(base, codec, w, 0x70500)
                cmd(base, codec, w, 0x70100 | p[i + 1])                  // connection select
                unmute(base, codec, w)
                i += 2
            }
        }
        cmd(base, codec, dac, 0x70500)
        unmute(base, codec, dac)
        // the first output stream: 48 kHz, 16-bit, 2 channels; stream tag 1
        let sd = base + 0x80 + 0x20 * iss
        let fmt = 0x0011
        cmd(base, codec, dac, 0x20000 | fmt)
        cmd(base, codec, dac, 0x70610)                             // stream 1, channel 0
        let o = Out { f, base, codec, dac, pins, sd, buf: kernel.alloc_pages(PERIODS * PERIOD * 4 / 4096 + 1), bdl: kernel.alloc_pages(1) }
        // reset the stream, then the buffer list: one entry per period
        kernel.poke8(sd, 1)
        until = now_ms() + 50
        while now_ms() < until && kernel.peek8(sd) & 1 == 0 {}
        kernel.poke8(sd, 0)
        until = now_ms() + 50
        while now_ms() < until && kernel.peek8(sd) & 1 != 0 {}
        for k in 0..PERIODS {
            kernel.poke64(o.bdl + 16 * k, o.buf + k * PERIOD * 4)
            kernel.poke32(o.bdl + 16 * k + 8, PERIOD * 4)
            kernel.poke32(o.bdl + 16 * k + 12, 0)
        }
        kernel.fill32(o.buf, PERIODS * PERIOD, 0)
        kernel.poke32(sd + 0x08, PERIODS * PERIOD * 4)               // cyclic buffer length
        kernel.poke16(sd + 0x0c, PERIODS - 1)                         // last valid index
        kernel.poke16(sd + 0x12, fmt)
        kernel.poke32(sd + 0x18, o.bdl & 0xffff_ffff)
        kernel.poke32(sd + 0x1c, o.bdl >> 32)
        kernel.poke8(sd + 2, 1 << 4)                                  // stream tag 1 (bits 20-23 of the control)
        kernel.poke8(sd, 2)                                           // run
        o.log.push("codec ${codec}: DAC ${dac}, pins ${pins}")
        kernel.every(10, () => o.pump())
        return some(o)
    }
    return none
}
