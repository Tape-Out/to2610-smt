/* 两个线程跑同一份程序，由引导程序搬进 SDRAM。0 号线程报数，1 号线程听它的口令干活。
 *   一个核时 SC 的三条规矩：有预留才写得成、没预留写不成、预留的不是这个字也写不成
 *   两个线程各加 N 次同一个数，四种加法：
 *     直接读了加一再写   必须丢数，丢了才说明两个线程真的在抢；不丢的话后面三项什么也证明不了
 *     amoadd             一个不丢
 *     amoswap 做的自旋锁 一个不丢，而且确实等过锁
 *     LR 与 SC           一个不丢，而且确实有过写不成重来的
 *   两个线程跑的是同一段循环，步子一样就会一直错开、谁也碰不上谁，所以每圈垫几条指令，两个线程垫的不一样
 *   预留跨线程作废：0 号线程 LR 之后1 号线程写了同一个字，SC 写不成；写的是别的字，SC 照样写成
 *   核间中断两个方向各一次，1 号线程自己的计时器中断一次
 *   1 号线程读到的 time 与 CLINT 的 mtime 是同一个数，夹在前后两次读 mtime 之间：放开之后、收回再放开之后各核一次
 *   收回1 号线程它就停，再放开它从头来
 */
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)
#define CSR_R(n) ({ uint32_t v_; __asm__ volatile("csrr %0, " #n : "=r"(v_)); v_; })
#define CSR_W(n, v) __asm__ volatile("csrw " #n ", %0" : : "r"((uint32_t)(v)))
#define CSR_S(n, v) __asm__ volatile("csrs " #n ", %0" : : "r"((uint32_t)(v)))

#define CTL 0x40040000u
#define RUN (CTL + 0x04)
#define CLINT_A 0x02000000u
#define CLINT_B 0x03000000u
#define MSIP 0x0000
#define MTIMECMP 0x4000
#define MTIME 0xbff8

#define N 200

enum { PLAIN = 1, AMO, SPIN, LRSC, VM, POKE_CELL, POKE_OTHER, LR_OTHER, IPI, TICK, NAP, POLL, TIME };

static volatile uint32_t cmd, ack, hart_b, beat, oops_b, napping, go;
static volatile uint32_t plain, added, lock, locked, cond;
static volatile uint32_t retry[2], waits[2], soft[2], tick_b;
static volatile uint32_t cell, other;
static volatile uint32_t time_ok, time_d;
/* 两个线程各一张根页表；虚地址 0x4000_0000 那一兆页，0 号映到 0x8080_0000，1 号映到 0x80C0_0000 */
static uint32_t pt[2][1024] __attribute__((aligned(4096)));
static volatile uint32_t vmbad[2];
#define VM_VA 0x40000000u
#define VM_PA(me) (0x80800000u + (me) * 0x400000u)
static uint32_t seq;

static void putch(char c) {
  while (!(LSR & 0x60)) {}
  REG(0x10000000) = c;
}

static void say(const char *s) {
  while (*s) putch(*s++);
}

static void hex(uint32_t v) {
  for (int i = 28; i >= 0; i -= 4) putch("0123456789abcdef"[v >> i & 15]);
}

static void verdict(const char *what, uint32_t bad, uint32_t detail) {
  say(what);
  say(bad ? " BAD " : " ok ");
  hex(detail);
  if (bad && oops_b) {
    say(" hart b trap ");
    hex(oops_b);
  }
  putch('\n');
}

static inline uint32_t amoswap(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("amoswap.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
  return r;
}

static inline void amoadd(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("amoadd.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
}

static inline uint32_t lr(volatile uint32_t *p) {
  uint32_t r;
  __asm__ volatile("lr.w %0, (%1)" : "=&r"(r) : "r"(p) : "memory");
  return r;
}

/* 回 0 是写成了 */
static inline uint32_t sc(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("sc.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
  return r;
}

/* 开着 MPRV（数据访存按监管态走页表）写一个字再读回来；中间只有这两次访存，栈与全局变量都不碰 */
static inline uint32_t vm_swap(uint32_t va, uint32_t v) {
  uint32_t r, mprv = 1 << 17;
  __asm__ volatile("csrs mstatus, %3\n sw %2, 0(%1)\n lw %0, 0(%1)\n csrc mstatus, %3"
                   : "=&r"(r) : "r"(va), "r"(v), "r"(mprv));
  return r;
}

static void work(uint32_t what, uint32_t me) {
  if (what == VM) {
    /* 大页的页表项：物理页号、有效、可读写、访问过与写过两位先置上；MPP 给监管态，MPRV 才按它走 */
    pt[me][VM_VA >> 22] = VM_PA(me) >> 2 | 0xc7;
    CSR_W(satp, 0x80000000u | (uint32_t)pt[me] >> 12);
    __asm__ volatile("csrc mstatus, %0\n csrs mstatus, %1" : : "r"(0x1800), "r"(0x0800));
  }
  for (uint32_t i = 0; i < N; i++) {
    for (volatile uint32_t d = 0; d < ((me ? i >> 1 : i) & 3); d++) {}
    switch (what) {
      case PLAIN: {
        uint32_t t = plain;
        for (volatile uint32_t d = 0; d < (i & 1); d++) {}
        plain = t + 1;
        break;
      }
      case AMO:
        amoadd(&added, 1);
        break;
      case VM: {
        uint32_t v = 0xa5000000 | me << 16 | i;
        vmbad[me] += vm_swap(VM_VA + i * 4, v) != v;
        break;
      }
      case SPIN: {
        while (amoswap(&lock, 1)) waits[me]++;
        uint32_t t = locked;
        /* 读与写之间隔开几条指令，锁不住的话这里一定丢数 */
        for (volatile uint32_t d = 0; d < 2; d++) {}
        locked = t + 1;
        lock = 0;
        break;
      }
      case LRSC:
        for (;;) {
          uint32_t v = lr(&cond);
          if (!sc(&cond, v + 1)) break;
          retry[me]++;
        }
        break;
    }
  }
  if (what == VM) {
    /* 页表关掉，MPP 放回机器态：之后的中断返回要按它定特权级 */
    CSR_S(mstatus, 0x1800);
    CSR_W(satp, 0);
  }
}

__attribute__((interrupt("machine"), aligned(4))) static void trap_a(void) {
  uint32_t c = CSR_R(mcause);
  if (c == 0x80000003) {
    REG(CLINT_A + MSIP) = 0;
    soft[0]++;
  } else {
    say("trap ");
    hex(c);
    putch(' ');
    hex(CSR_R(mepc));
    putch('\n');
    for (;;) {}
  }
}

__attribute__((interrupt("machine"), aligned(4))) static void trap_b(void) {
  uint32_t c = CSR_R(mcause);
  if (c == 0x80000003) {
    REG(CLINT_B + MSIP) = 0;
    soft[1]++;
  } else if (c == 0x80000007) {
    REG(CLINT_B + MTIMECMP + 4) = 0xffffffff;
    tick_b++;
  } else {
    /* 串口归0 号线程：这里只留下原因，由它报 */
    oops_b = c;
    for (;;) {}
  }
}

void main_b(void) {
  CSR_W(mtvec, (uint32_t)trap_b);
  REG(CLINT_B + MTIMECMP + 4) = 0xffffffff;
  CSR_S(mie, 1 << 3 | 1 << 7);
  CSR_S(mstatus, 1 << 3);
  /* 再放开时上一条口令已经办过了 */
  uint32_t seen = cmd;
  hart_b = 0x100 | CSR_R(mhartid);
  for (;;) {
    beat++;
    uint32_t c = cmd;
    if (c == seen) continue;
    seen = c;
    switch (c & 0xff) {
      case POKE_CELL:
        cell = 0x77;
        break;
      case POKE_OTHER:
        other = 0x55;
        break;
      case LR_OTHER:
        lr(&other);
        break;
      case IPI:
        REG(CLINT_A + MSIP) = 1;
        break;
      case TICK:
        REG(CLINT_B + MTIMECMP) = REG(CLINT_B + MTIME) + 200;
        REG(CLINT_B + MTIMECMP + 4) = REG(CLINT_B + MTIME + 4);
        break;
      case TIME: {
        uint32_t t0 = REG(CLINT_A + MTIME);
        uint32_t tb = CSR_R(time);
        uint32_t t1 = REG(CLINT_A + MTIME);
        time_d = tb - t0;
        time_ok = tb - t0 <= t1 - t0;
        break;
      }
      case NAP: {
        /* 睡到下一个核间中断来 */
        uint32_t s = soft[1];
        napping = 1;
        while (soft[1] == s) __asm__ volatile("wfi");
        napping = 0;
        break;
      }
      case POLL:
        /* 拿 WFI 当停顿，等的是内存里的一个数，不会有中断来 */
        napping = 1;
        while (!go) __asm__ volatile("wfi");
        napping = 0;
        break;
      default:
        work(c & 0xff, 1);
    }
    ack = c;
  }
}

/* 等一个条件，最多 ms 毫秒（mtime 每微秒走一格）；回 1 是没等到 */
#define UNTIL(cond, ms) ({ uint32_t t0_ = REG(CLINT_A + MTIME); \
                          while (!(cond) && REG(CLINT_A + MTIME) - t0_ < (ms) * 1000u) {} \
                          !(cond); })

/* us 微秒里自己空转了多少圈 */
static uint32_t turns(uint32_t us) {
  uint32_t n = 0, t0 = REG(CLINT_A + MTIME);
  while (REG(CLINT_A + MTIME) - t0 < us) n++;
  return n;
}

/* 只让1 号线程干 */
static uint32_t ask(uint32_t what) {
  uint32_t c = ++seq << 8 | what;
  cmd = c;
  return UNTIL(ack == c, 100);
}

/* 两个线程一起干 */
static uint32_t both(uint32_t what) {
  uint32_t c = ++seq << 8 | what;
  cmd = c;
  work(what, 0);
  return UNTIL(ack == c, 300);
}

int main(void) {
  /* 主频寄存器是 8.8 定点的兆赫 */
  uint32_t hz = (REG(0x10000014) & 0xffff) * 15625 / 4;
  REG(0x1000000c) = hz / 115200;
  say("to2610 smt\n");
  CSR_W(mtvec, (uint32_t)trap_a);
  CSR_S(mie, 1 << 3);
  CSR_S(mstatus, 1 << 3);

  verdict("ident", REG(CTL) != 0x534d5431 || REG(RUN) != 0, REG(CTL));
  verdict("hart", CSR_R(mhartid) != 0, CSR_R(mhartid));

  cell = 5;
  other = 3;
  uint32_t v = lr(&cell);
  uint32_t f = sc(&cell, v + 1);
  verdict("sc same", f != 0 || cell != 6, cell);
  f = sc(&cell, 9);
  verdict("sc alone", f == 0 || cell != 6, cell);
  lr(&cell);
  f = sc(&other, 7);
  /* 写错了字的那一次也把预留用掉了 */
  uint32_t g = sc(&cell, 8);
  verdict("sc other", f == 0 || g == 0 || other != 3 || cell != 6, other << 16 | cell);

  REG(RUN) = 1;
  uint32_t bad = UNTIL(hart_b != 0, 100);
  verdict("hart b", bad || hart_b != 0x101, hart_b);

  bad = both(PLAIN);
  say("plain ");
  hex(plain);
  putch('\n');
  verdict("race", bad || plain >= 2 * N, bad);
  bad = both(AMO);
  verdict("amo", bad || added != 2 * N, added);
  bad = both(SPIN);
  say("waits ");
  hex(waits[0]);
  putch(' ');
  hex(waits[1]);
  putch('\n');
  verdict("spin", bad || locked != 2 * N || lock != 0 || waits[0] + waits[1] == 0, locked);
  bad = both(LRSC);
  say("retry ");
  hex(retry[0]);
  putch(' ');
  hex(retry[1]);
  putch('\n');
  verdict("lrsc", bad || cond != 2 * N || retry[0] + retry[1] == 0, cond);

  /* 两个线程各开各的页表：同一个虚地址各写各读两百次，读回的都是自己写的；按物理地址看，各落在各的那一页 */
  bad = both(VM);
  for (uint32_t h = 0; h < 2; h++)
    bad |= REG(VM_PA(h)) != (0xa5000000 | h << 16) || REG(VM_PA(h) + 4 * (N - 1)) != (0xa5000000 | h << 16 | (N - 1));
  verdict("vm", bad || vmbad[0] || vmbad[1], vmbad[1] << 16 | vmbad[0]);

  cell = 5;
  v = lr(&cell);
  bad = ask(POKE_CELL);
  f = sc(&cell, v + 1);
  verdict("kill", bad || f == 0 || cell != 0x77, cell);
  v = lr(&cell);
  bad = ask(POKE_OTHER);
  f = sc(&cell, v + 1);
  verdict("keep", bad || f != 0 || cell != 0x78 || other != 0x55, cell);
  /* 对面只是预留了别的字：这一边的预留照旧 */
  v = lr(&cell);
  bad = ask(LR_OTHER);
  f = sc(&cell, v + 1);
  verdict("apart", bad || f != 0 || cell != 0x79, cell);

  bad = ask(IPI) | UNTIL(soft[0] == 1, 100);
  REG(CLINT_B + MSIP) = 1;
  bad |= UNTIL(soft[1] == 1, 100);
  verdict("ipi", bad || REG(CLINT_A + MSIP) != 0 || REG(CLINT_B + MSIP) != 0, soft[1] << 16 | soft[0]);
  bad = ask(TICK) | UNTIL(tick_b == 1, 100);
  verdict("tick", bad, tick_b);
  bad = ask(TIME);
  verdict("time", bad || !time_ok, time_d);

  /* 两个线程共用一个核才有的两条。对面在忙时两边一人一条指令；对面睡着（WFI，没有开着又挂起的中断）时拍子都归这一边，
     同样的时间里转的圈数至少是一倍半。对面的中断一来就排回轮转，不必等「每跳过 63 次轮到一次」：一百微秒里要应到 */
  uint32_t slow = turns(2000);
  uint32_t c = ++seq << 8 | NAP;
  cmd = c;
  bad = UNTIL(napping, 100);
  uint32_t fast = turns(2000);
  uint32_t t0 = REG(CLINT_A + MTIME);
  REG(CLINT_B + MSIP) = 1;
  bad |= UNTIL(soft[1] == 2, 100);
  uint32_t late = REG(CLINT_A + MTIME) - t0;
  bad |= UNTIL(ack == c, 100);
  say("turns ");
  hex(slow);
  putch(' ');
  hex(fast);
  putch('\n');
  verdict("nap", bad || fast * 2 < slow * 3, fast * 100 / slow);
  verdict("wake", bad || late > 100, late);
  /* 对面拿 WFI 当停顿、靠轮询内存等这一边，没有中断会来：睡着的线程每跳过 63 次轮到一次，它等得到 */
  c = ++seq << 8 | POLL;
  cmd = c;
  bad = UNTIL(napping, 100);
  go = 1;
  bad |= UNTIL(ack == c, 100);
  verdict("poll", bad, napping);

  REG(RUN) = 0;
  for (volatile uint32_t i = 0; i < 200; i++) {}
  uint32_t b0 = beat;
  for (volatile uint32_t i = 0; i < 2000; i++) {}
  verdict("stop", beat != b0 || REG(RUN) != 0, REG(RUN));
  hart_b = 0;
  REG(RUN) = 1;
  bad = UNTIL(hart_b != 0, 100) | ask(POKE_OTHER);
  verdict("again", bad || hart_b != 0x101, hart_b);
  bad = ask(TIME);
  verdict("time again", bad || !time_ok, time_d);
  say("done\n");
  for (;;) {}
}
