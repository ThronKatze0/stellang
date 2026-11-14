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

- [ ] A. Build: `stellang --kernel --arch x86_64` → `os.efi`; `stellang boot --arch x86_64 [--gui]`
      runs QEMU + OVMF (`-drive fat:` dir, `-device qemu-xhci -device usb-mouse`).
- [ ] B. runtime split + `runtime_kernel_x86.c` + `boot_uefi.c`
- [ ] C. RV64 interpreter for user processes on x86
- [ ] D. stellang side: `kernel.arch()`, port I/O, `time_ms`, display/virtio/rng on x86
- [ ] E. PS/2 keyboard + mouse in input.st
- [ ] F. `pci.st`, `xhci.st`, USB HID boot-protocol mouse + keyboard
- [ ] G. HiDPI: integer upscale of the 1024x768 desktop when the panel is ≥ 2048 wide
- [ ] H. README: making the USB stick, Secure Boot off, what works / what doesn't

## Testing

```sh
stellang boot --arch x86_64 --gui examples/stellaos/os.st   # QEMU x86_64 + OVMF
```

OVMF on Arch: `/usr/share/edk2/x64/OVMF_CODE.4m.fd`; Debian: `/usr/share/OVMF/OVMF_CODE.fd`
(`STELLANG_OVMF` overrides).
