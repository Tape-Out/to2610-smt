# mpc-frame 两个测试台用的程序：读核间那一页的标识寄存器，对了从串口发 M（0x4d），不对发 X（0x58）。
# 1 号线程不放开，测试台就不必带 SDRAM 的模型
# expect: 4d
.section .text
.global _start
_start:
    li t0, 0x1000000c
    li t1, 16
    sw t1, 0(t0)
    li t0, 0x40040000
    lw t2, 0(t0)
    li t3, 0x534d5031
    li t1, 0x4d
    beq t2, t3, 1f
    li t1, 0x58
1:  li t0, 0x10000000
    sw t1, 0(t0)
2:  j 2b
