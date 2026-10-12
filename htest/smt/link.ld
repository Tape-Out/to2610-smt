OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0x80000000, LENGTH = 512K }
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) *(.data*) *(.sdata*) } > ram
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*) *(.bss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > ram
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame) }
}
