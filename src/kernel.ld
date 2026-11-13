/* stellang --kernel: the layout of a kernel for QEMU's RISC-V `virt` machine (OpenSBI jumps to 0x80200000) */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    . = ALIGN(16);
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
    . = ALIGN(16);
    __data_start = .;
    .data : { *(.data .data.* .sdata .sdata.*) }
    . = ALIGN(16);
    __bss_start = .;
    .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }
    . = ALIGN(16);
    __bss_end = .;
    .stack (NOLOAD) : {
        . += 0x80000; /* 512 KiB */
    }
    __stack_top = .;
    . = ALIGN(65536);
    __kernel_end = .;
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment .note .note.* .riscv.attributes) }
}
