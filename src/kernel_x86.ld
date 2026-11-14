/* stellang --kernel --arch x86_64: the kernel's layout. Position-independent (linked at 0): the UEFI
   loader (boot_uefi.c) puts it wherever the firmware has room and applies its relocations. */
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS
{
    . = 0;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    . = ALIGN(4096);
    .rodata : { *(.rodata .rodata.*) }
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .gnu.hash : { *(.gnu.hash) }
    .hash : { *(.hash) }
    .rela.dyn : { *(.rela .rela.*) }
    . = ALIGN(4096);
    .dynamic : { *(.dynamic) }
    . = ALIGN(16);
    __data_start = .;
    .data : { *(.data .data.* .got .got.*) }
    . = ALIGN(16);
    __bss_start = .;
    .bss : { *(.bss .bss.* COMMON) }
    . = ALIGN(16);
    __bss_end = .;
    .stack (NOLOAD) : {
        . += 0x100000; /* 1 MiB */
    }
    __stack_top = .;
    . = ALIGN(65536);
    __kernel_end = .;
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment .note .note.* .interp) }
}
