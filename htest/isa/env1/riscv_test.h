/* 上游的 p 环境在入口把 0 号以外的 hart 挡住。测试放到 1 号线程上跑时反过来：挡住 0 号，放 1 号过去 */
#include_next "riscv_test.h"
#undef RISCV_MULTICORE_DISABLE
#define RISCV_MULTICORE_DISABLE csrr a0, mhartid; addi a0, a0, -1; 1: bnez a0, 1b
