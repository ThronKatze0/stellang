// pci: the devices on a PC's PCI bus, found through configuration space (I/O ports 0xcf8/0xcfc,
// which every x86 PC has). Drivers (xhci.st) look for their kind of device here, then talk to it
// through the memory its BARs point at.
//
// This only reads configuration space, except for what a driver asks for on its own device: turning
// on memory access and DMA (`enable`) and waking it from a power-saving state (`wake`).

import kernel

const ADDR = 0xcf8
const DATA = 0xcfc

struct Function {
    bus: int,
    dev: int,
    func: int,
    vendor: int,
    device: int,
    class: int,               // 0x0c: serial bus controllers
    subclass: int,            // 0x03: USB
    progif: int,              // 0x30: xHCI

    fn read(self, off: int) -> int {
        kernel.outl(ADDR, 0x8000_0000 | (self.bus << 16) | (self.dev << 11) | (self.func << 8) | (off & 0xfc))
        return kernel.inl(DATA) & 0xffff_ffff
    }

    fn write(self, off: int, v: int) {
        kernel.outl(ADDR, 0x8000_0000 | (self.bus << 16) | (self.dev << 11) | (self.func << 8) | (off & 0xfc))
        kernel.outl(DATA, v & 0xffff_ffff)
    }

    // The memory BAR `i` points at (64-bit BARs take two slots), or 0 for none / an I/O BAR.
    fn bar(self, i: int) -> int {
        let lo = self.read(0x10 + 4 * i)
        if lo & 1 != 0 { return 0 }
        var a = lo & 0xffff_fff0
        if (lo >> 1) & 3 == 2 { a = a | (self.read(0x14 + 4 * i) << 32) }
        return a
    }

    // Let the device answer at its BARs and do DMA (memory space + bus master).
    fn enable(self) {
        let cmd = self.read(4) & 0xffff
        self.write(4, cmd | 6)        // the upper half (status) is write-1-to-clear: written as 0
    }

    // Bring the device to full power (D0) if the firmware left it asleep.
    fn wake(self) {
        if (self.read(4) >> 16) & 0x10 == 0 { return }   // no capability list
        var at = self.read(0x34) & 0xfc
        var n = 0
        while at != 0 && n < 48 {
            let c = self.read(at)
            if c & 0xff == 1 {                        // power management
                let pmcsr = self.read(at + 4)
                if pmcsr & 3 != 0 {
                    self.write(at + 4, pmcsr & ~3)
                    sleep(10)
                }
                return
            }
            at = (c >> 8) & 0xfc
            n += 1
        }
    }
}

fn function(bus: int, dev: int, func: int) -> Function? {
    let f = Function { bus, dev, func, vendor: 0, device: 0, class: 0, subclass: 0, progif: 0 }
    let id = f.read(0)
    if id & 0xffff == 0xffff { return none }
    f.vendor = id & 0xffff
    f.device = id >> 16
    let cls = f.read(8)
    f.class = cls >> 24
    f.subclass = (cls >> 16) & 0xff
    f.progif = (cls >> 8) & 0xff
    return some(f)
}

// Every device function on the machine (all 256 buses: simple, and quick enough at boot).
fn all() -> [Function] {
    var out: [Function] = []
    if kernel.arch() != "x86_64" { return out }
    for bus in 0..256 {
        for dev in 0..32 {
            if let f0 = function(bus, dev, 0) {
                out.push(f0)
                // more functions only if the header type says so
                if (f0.read(0x0c) >> 16) & 0x80 != 0 {
                    for func in 1..8 {
                        if let f = function(bus, dev, func) { out.push(f) }
                    }
                }
            }
        }
    }
    return out
}

// The functions of one kind (class, subclass, programming interface).
fn find(class: int, subclass: int, progif: int) -> [Function] {
    return all().filter(f => f.class == class && f.subclass == subclass && f.progif == progif)
}
