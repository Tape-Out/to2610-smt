/* 两个线程进同一个入口：1 号线程的复位地址就是 SDRAM 起始处，放开时这段程序已经由引导程序搬好。
 * 按 mhartid 分栈；.bss 只由0 号线程清，那时1 号线程还在复位里。
 */
.section .text.start
.global _start
_start:
    csrr t0, mhartid
    bnez t0, 2f
    la t1, __bss_start
    la t2, __bss_end
1:  bgeu t1, t2, 3f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 1b
3:  li sp, 0x80100000
    call main
4:  j 4b
2:  li sp, 0x800c0000
    call main_b
5:  j 5b
