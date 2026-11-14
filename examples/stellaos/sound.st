// sound: a driver for the virtio sound card (QEMU's virtio-sound-device), written in stellang,
// and a little synthesizer on top: tones (square waves with soft edges, so they don't click),
// several at once, mixed into 16-bit samples.
//
// The card has a control queue (questions and commands: what streams are there, set the format,
// start) and a transmit queue: each buffer we put there is [stream id][samples][status], and the
// card hands it back once it has played it. We keep a few buffers queued (about 80 ms) while there
// is something to play, and none while it's quiet.

import kernel
import virtio

const DEVICE = 25

// control requests
const PCM_INFO = 0x0100
const PCM_SET_PARAMS = 0x0101
const PCM_PREPARE = 0x0102
const PCM_START = 0x0104
const PCM_STOP = 0x0105
const S_OK = 0x8000

const FMT_S16 = 5
const RATES = [5512, 8000, 11025, 16000, 22050, 32000, 44100, 48000, 64000, 88200, 96000, 176400, 192000, 384000]

const PERIOD_MS = 20
const QUEUED = 4              // periods in flight
const VOICES = 8
const VOLUME = 2600           // of 32767

struct Tone {
    step: int,                // phase step per sample (of 2^32)
    phase: int = 0,
    left: int,                // samples still to play
    total: int,
}

struct Card {
    dev: virtio.Device,
    ctl: virtio.Queue,
    tx: virtio.Queue,
    stream: int,
    rate: int,
    channels: int,
    mem: int,                 // a page for control messages
    bufs: [int] = [],         // period buffers (each: header, samples, status)
    free: [int] = [],
    period: int = 0,          // samples per period
    tones: [Tone] = [],
    in_flight: int = 0,
    played: int = 0,          // periods played, for `sound` in the shell
    tail: int = 0,            // silent periods still to send after the last tone
    running: bool = false,

    fn control(self, req: [int], req_len: int, resp_len: int) -> int {
        for k, w in req { kernel.poke32(self.mem + 4 * k, w) }
        let resp = self.mem + 1024
        kernel.fill32(resp, resp_len / 4 + 1, 0)
        let head = self.ctl.offer([
            virtio.Buf { addr: self.mem, len: req_len, writable: false },
            virtio.Buf { addr: resp, len: resp_len, writable: true },
        ])
        if head < 0 { return -1 }
        self.ctl.notify()
        let until = kernel.uptime() + 1000
        while kernel.uptime() < until {
            if let u = self.ctl.take() { return kernel.peek32(resp) }
        }
        return -1
    }

    // Play a tone: hz for ms milliseconds (mixed with whatever else is playing).
    fn beep(self, hz: int, ms: int) {
        if self.tones.len() >= VOICES { self.tones.remove(0) }
        let n = self.rate * ms / 1000
        self.tones.push(Tone { step: (hz << 32) / self.rate, left: n, total: n })
        self.tail = 2
        self.pump()
    }

    fn busy(self) -> bool { return !self.tones.is_empty() }

    // Keep the card fed: called often (a timer); fills and queues periods while there is sound.
    fn pump(self) {
        while true {
            if let u = self.tx.take() {
                self.free.push(self.buf_of(u.head))
                self.in_flight -= 1
                self.played += 1
            } else {
                break
            }
        }
        if self.tones.is_empty() && self.tail == 0 {
            if self.running && self.in_flight == 0 {
                self.control([PCM_STOP, self.stream], 8, 4)
                self.running = false
            }
            return
        }
        if !self.running {
            self.control([PCM_START, self.stream], 8, 4)
            self.running = true
        }
        while self.in_flight < QUEUED && !self.free.is_empty() {
            if self.tones.is_empty() {
                if self.tail == 0 { break }
                self.tail -= 1
            }
            let b = self.free.pop()
            self.fill(b + 16)
            kernel.poke32(b, self.stream)
            let bytes = self.period * 2 * self.channels
            let head = self.tx.offer([
                virtio.Buf { addr: b, len: 4, writable: false },
                virtio.Buf { addr: b + 16, len: bytes, writable: false },
                virtio.Buf { addr: b + 8, len: 8, writable: true },
            ])
            if head < 0 {
                self.free.push(b)
                break
            }
            self.in_flight += 1
            self.tx.notify()
        }
    }

    fn buf_of(self, head: int) -> int { return self.tx.addr_of(head) }

    // one period of samples: the tones, mixed
    fn fill(self, at: int) {
        let n = self.period
        let mix = render(self.tones, n, self.rate)
        self.tones = self.tones.filter(t => t.left > 0)
        for i in 0..n {
            let v = mix[i] & 0xffff
            if self.channels == 1 {
                kernel.poke16(at + 2 * i, v)
            } else {
                kernel.poke32(at + 4 * i, v | v << 16)
            }
        }
    }
}

// The next `n` samples of the tones playing (16-bit, mixed), each tone moved on; tones that are
// done have left == 0 after.
fn render(tones: [Tone], n: int, rate: int) -> [int] {
    let ramp = rate / 500                    // 2 ms in and out
    var mix: [int] = []
    for i in 0..n { mix.push(0) }
    for t in tones {
        let count = min(n, t.left)
        var phase = t.phase
        var done = t.total - t.left
        for i in 0..count {
            var v = if phase & 0x8000_0000 == 0 { VOLUME } else { -VOLUME }
            let rest = t.total - done
            if done < ramp { v = v * done / ramp }
            if rest < ramp { v = v * rest / ramp }
            mix[i] = mix[i] + v
            phase = (phase + t.step) & 0xffff_ffff
            done += 1
        }
        t.phase = phase
        t.left -= count
    }
    for i in 0..n { mix[i] = max(-32767, min(32767, mix[i])) }
    return mix
}

// The sound card, if QEMU has one (`stellang boot` adds it).
fn open() -> Card? {
    for d in virtio.find(DEVICE) {
        if !d.start(0) { continue }
        let ctl = d.queue(0, 16) catch e { continue }
        d.queue(1, 16) catch e { continue }
        let tx = d.queue(2, 16) catch e { continue }
        d.queue(3, 16) catch e { continue }
        d.go()
        let streams = d.config32(4)
        let mem = kernel.alloc_pages(1)
        let c = Card { dev: d, ctl, tx, stream: -1, rate: 0, channels: 1, mem }
        // the first output stream, and the lowest rate of 22050 or more that it does
        for sid in 0..streams {
            let st = c.control([PCM_INFO, sid, 1, 32], 16, 4 + 32)
            if st != S_OK { continue }
            let info = mem + 1024 + 4
            let formats = kernel.peek64(info + 8)
            let rates = kernel.peek64(info + 16)
            let direction = kernel.peek8(info + 24)
            let cmin = kernel.peek8(info + 25)
            if direction != 0 || formats & (1 << FMT_S16) == 0 { continue }
            var rate_i = -1
            for k, r in RATES {
                if rate_i < 0 && r >= 22050 && rates & (1 << k) != 0 { rate_i = k }
            }
            if rate_i < 0 { continue }
            c.stream = sid
            c.rate = RATES[rate_i]
            c.channels = max(1, cmin)
            c.period = c.rate * PERIOD_MS / 1000
            let bytes = c.period * 2 * c.channels
            // set_params: hdr, stream, buffer bytes, period bytes, features, then channels/format/rate
            let ps = c.control([PCM_SET_PARAMS, sid, bytes * QUEUED, bytes, 0, c.channels | FMT_S16 << 8 | rate_i << 16], 24, 4)
            if ps != S_OK { continue }
            if c.control([PCM_PREPARE, sid], 8, 4) != S_OK { continue }
            // the period buffers: 16 bytes of header and status, then the samples
            let per = (16 + bytes + 4095) / 4096
            for k in 0..QUEUED + 2 {
                let b = kernel.alloc_pages(per)
                c.bufs.push(b)
                c.free.push(b)
            }
            kernel.every(10, () => c.pump())
            return some(c)
        }
    }
    return none
}
