O ?= build
CROSS ?= riscv64-unknown-elf-

$(O)/smt.bin: start.S smt.c link.ld
	mkdir -p $(O)
	$(CROSS)gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -mno-relax -ffreestanding -nostdlib -Wl,-T,link.ld -o $(O)/smt.elf start.S smt.c
	$(CROSS)objcopy -O binary $(O)/smt.elf $@
