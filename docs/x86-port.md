# StellaOS on x86_64 (real laptops, UEFI)

Branch `stellaos-x86`. Goal: boot StellaOS from a USB stick on an x86_64 UEFI laptop
(target machine: Intel i9-14900HX laptop), with the desktop on the built-in screen, the keyboard,
and a USB mouse. RISC-V/QEMU must keep working unchanged.

## Safety rules (do not break)

- RAM-only on real hardware: no NVMe/AHCI/SATA driver, no writes to any real disk. The file system
  lives in RAM (`disk.open()` finds nothing on x86).
- No writes to firmware flash, no SMM, no microcode.
- Shutdown/reboot only through UEFI runtime services `ResetSystem`.
- Never `dd` in tooling. The USB image is a folder (`EFI/BOOT/BOOTX64.EFI`) copied onto a FAT32 stick.

## Design

- **Two stages.** The kernel stays a SysV ELF (`x86_64-unknown-none`, static PIE, `-mno-red-zone`),
  so the IR codegen makes for the native host still works unchanged. A small UEFI loader
  (`src/boot_uefi.c`, PE built with `--target=x86_64-unknown-windows`, lld-link) embeds the ELF.
  The loader gets the GOP framebuffer, the memory map, ACPI RSDP and the runtime services, then
  calibrates the TSC with `Stall`, calls ExitBootServices, relocates the ELF (R_X86_64_RELATIVE)
  and jumps to it with a `BootInfo *`.
- **The kernel runtime is split.** `runtime_kernel.c` holds the arch-independent parts (gfx, ui,
  timers, memory helpers). `runtime_kernel_rv.c` and `runtime_kernel_x86.c` hold boot, traps, the
  console, time, power and processes for each arch.
- **x86 interrupts.** The kernel sets up its own GDT and IDT and its own identity page tables
  (512 GiB in 1 GiB pages; framebuffer WC, MMIO UC through PAT). The LAPIC timer runs at 1 kHz,
  works in xAPIC or x2APIC mode, and is calibrated against the TSC. The 8259 PIC is masked. The
  timer ISR polls the i8042 (PS/2 keyboard and mouse) into a ring. xHCI is polled from the main loop.
- **Processes.** User programs are RISC-V machine code (cc.st). On x86, `st_k_user_run` interprets
  RV64IM over the same frame layout and walks the Sv39 page table in software, so proc.st does not
  change.
- **Time.** UEFI `GetTime` at boot plus the TSC. **Power:** UEFI `ResetSystem`. **Randomness:** RDRAND.
- **Drivers (stellang).** `kernel.arch()` picks the path. On x86: display = the GOP framebuffer from
  BootInfo; input = PS/2 (C ring) + `xhci.st`/USB HID boot protocol (mouse, keyboard). Virtio,
  disk, net and sound find nothing on x86.

## Tasks / status

- [x] A. Build: `stellang --kernel --arch x86_64` → `os.efi`; `stellang boot --arch x86_64 [--gui]`
      runs QEMU + OVMF (`-drive fat:` dir, `-device qemu-xhci -device usb-mouse`).
- [x] B. runtime split + `runtime_kernel_x86.c` + `boot_uefi.c`
- [x] C. RV64 interpreter for user processes on x86. Fixed: store offsets (`imm_s`) were
      zero-extended, so every `sd x, -n(sp)` faulted. tests/stellaos_procs.st passes on x86 except
      the two memory-heavy programs, which hit the 3 s limit under QEMU's x86 emulation (no KVM here).
- [x] D. display.st on x86: `Screen` over the GOP framebuffer (stride, RGB/BGR via `gfx.SWAP_RB`),
      `display.size()`; wm.st composes into its back buffer and calls `Screen.show` per damaged rect.
      The loader accepts bitmask modes with standard masks, refuses Blt-only, and swaps a mode under
      1024 wide for the biggest one up to 4K.
- [x] E. PS/2 keyboard (scan code set 1, E0/E1, repeats) + mouse (IntelliMouse wheel, 4-byte packets)
- [x] F. `pci.st`, `xhci.st`: BIOS handoff, scratchpads, command/event rings (polled), port reset,
      Address Device, Evaluate Context for full-speed EP0, config parsing, SET_PROTOCOL boot, interrupt
      IN endpoints, EP0/endpoint stall recovery, hotplug (scan every second, Disable Slot on unplug).
- [x] G. HiDPI: integer scale = the largest with ≥ 1024x720 desktop pixels (2560x1600 → 2x, 1280x800);
      the scaled blit widens each row once and memcpys it (never reads the WC framebuffer).
- [x] H. README: making the USB stick, Secure Boot off, what works / what doesn't.

Also done: identity map now covers the CPU's whole physical address width (up to 48 bits; tables
above 512 GiB come from RAM) — QEMU put the xHCI BAR at 768 GiB, and real 64-bit BARs (GPU
framebuffers) can be up there too. Unknown device vectors get an EOI; NMIs are ignored. `hw` shell
command (display, PS/2, USB devices + driver log). e2e test `stellaos_x86`.

Also done: USB hubs (USB 2 and 3, also chained): set up like a device, then the controller is told
it's a hub (Configure Endpoint with the slot context's hub bit, port count, TT think time), its ports
are powered and polled every second (GET_STATUS / port reset / clear changes), and devices behind
them get a route string, and the translator hub and port when they're full/low speed behind a
high-speed hub. Unplugging a hub takes down everything behind it. Tested in QEMU (`usb-hub` with a
keyboard and a mouse behind it, unplug and replug through the monitor); the USB 3 hub path
(SET_HUB_DEPTH, the USB 3 hub descriptor, warm-reset change) is written to the spec but untested
(QEMU has no USB 3 hub).

Not done: touchpads (I²C HID on most new laptops), network, sound, NVMe (on purpose).

## Testing

```sh
stellang boot --arch x86_64 --gui examples/stellaos/os.st   # QEMU x86_64 + OVMF
```

OVMF on Arch: `/usr/share/edk2/x64/OVMF_CODE.4m.fd`; Debian: `/usr/share/OVMF/OVMF_CODE.fd`
(`STELLANG_OVMF` overrides).

## Where it stands (keep this current)

- In QEMU x86 (q35 + OVMF): boots to the desktop on the GOP framebuffer (1280x800, and 2x on a
  2560x1600 `-device VGA,edid=on,xres=2560,yres=1600`), PS/2 keyboard + mouse, USB keyboard + mouse
  (incl. hotplug, and behind hubs), compiled programs run, `shutdown` exits.
- Not yet tried on the real laptop. First thing to run there: `hw`.
