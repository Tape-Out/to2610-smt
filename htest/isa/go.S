# Flash 里的复位入口，0 号线程从这里起：放开 1 号线程（它从 SDRAM 的 0x8000_0000 起，就是测试程序的入口），再照 MODE 办。
#   0  自己也去跑测试程序；1 号被测试环境挡在入口的一条转圈指令上，两个线程一人一条指令地轮
#   1  睡着：1 号线程独自跑测试
#   2  忙着：不停地改自己的寄存器与 CSR、读写自己的内存、做自己的 LR/SC 与 AMO，1 号线程跑测试时哪一样都不该受影响
.section .text
.global _start
_start:
    li t1, 0x40040004
    li t2, 1
    sw t2, 0(t1)
#if MODE == 0
    lui t0, 0x80000
    jr t0
#elif MODE == 1
1:  wfi
    j 1b
#else
    # 自己的内存取 SDRAM 的最后一兆，测试程序用不到那里
    li sp, 0x81f00000
    li t3, 0x12345678
1:  addi t3, t3, 0x155
    xori ra, t3, -1
    slli gp, t3, 3
    srli tp, t3, 5
    add t0, t3, ra
    sub t1, gp, tp
    or t2, t0, t1
    and s0, t2, t3
    xor s1, s0, ra
    mv a0, t3
    mv a1, ra
    mv a2, gp
    mv a3, tp
    mv a4, t0
    mv a5, t1
    mv a6, t2
    mv a7, s0
    mv s2, s1
    mv s3, a0
    mv s4, a1
    mv s5, a2
    mv s6, a3
    mv s7, a4
    mv s8, a5
    mv s9, a6
    mv s10, a7
    mv s11, s2
    mv t4, s3
    mv t5, s4
    mv t6, s5
    csrw mscratch, t3
    csrw mepc, t4
    csrw mtvec, t5
    sw t3, 0(sp)
    lw a1, 0(sp)
    lr.w a2, (sp)
    sc.w a3, t3, (sp)
    amoadd.w a4, t3, (sp)
    j 1b
#endif
