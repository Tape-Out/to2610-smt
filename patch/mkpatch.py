"""由 to2610-smp 那棵源码树改出这一颗的，并把差别存成 patch/smt.patch：两个核加仲裁换成一个核、两个硬件线程。

核里只有一套状态机与数据通路，体系结构状态每个线程一份：通用寄存器、PC、CSR 与特权级、地址转换（satp 与 TLB）、LR 的预留。
线程只在两条指令之间轮换；一个线程执行 WFI 而没有开着又挂起的中断时，轮转跳过它，把拍子都让给另一个。
软件看到的与 to2610-smp 一样：0 号、1 号两个 hart，各有各的 CLINT 与外部中断，1 号由核间那一页放开、从 SDRAM 起步。

补丁是提交进仓的那一份，拼源码树时只套补丁；上游变了、补丁套不上时，用这个脚本对着新的重出。
用法：mkpatch.py <to2610-smp 拼好的源码树 build/src> > patch/smt.patch
"""
import difflib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
K = "kianv_harris_edition/"

REGFILE = [
    ("    input  wire [ 4:0] A1,\n    input  wire [ 4:0] A2,\n    input  wire [ 4:0] A3,\n",
     "    input  wire [ 5:0] A1,\n    input  wire [ 5:0] A2,\n    input  wire [ 5:0] A3,\n"),
    ("  reg [31:0] bank0[0:31];\n", "  reg [31:0] bank0[0:63];\n"),
    ("    if (we && A3 != 0) begin\n", "    if (we && A3[4:0] != 0) begin\n"),
    ("  assign rd1 = A1 != 0 ? bank0[A1] : 32'b0;\n  assign rd2 = A2 != 0 ? bank0[A2] : 32'b0;\n",
     "  assign rd1 = A1[4:0] != 0 ? bank0[A1] : 32'b0;\n  assign rd2 = A2[4:0] != 0 ? bank0[A2] : 32'b0;\n"),
]

FSM = [
    ("    output wire sc_write,\n    input wire sc_abort\n);\n",
     "    output wire sc_write,\n    input wire sc_abort,\n    output wire next_instr\n);\n"),
    ("  assign sc_write = state == AMO_SC_WRITE;\n",
     "  assign sc_write = state == AMO_SC_WRITE;\n"
     "  // 这一拍过后去取下一条指令：换线程只在这里\n"
     "  assign next_instr = state != FETCH && state_nxt == FETCH && !stall;\n"),
]

CONTROL = [
    ("    output wire sc_write,\n    input  wire sc_abort\n);\n",
     "    output wire sc_write,\n    input  wire sc_abort,\n    output wire next_instr\n);\n"),
    ("      .sc_abort (sc_abort),\n", "      .sc_abort (sc_abort),\n      .next_instr(next_instr),\n"),
]

CSR = [
    ("    output wire                      IRQ_TO_CPU_CTRL11\n);\n",
     "    output wire                      IRQ_TO_CPU_CTRL11,\n    output wire                      wake\n);\n"),
    ("  wire [31:0] stimecmph;\n",
     "  wire [31:0] stimecmph;\n"
     "  // WFI 该醒的条件：开着的中断里有挂起的，不看全局使能\n"
     "  assign wake = |(mie & mip_current);\n"),
]

DATAPATH = [
    ("module datapath_unit #(\n    parameter RESET_ADDR = 0,\n    parameter HART_ID = 0\n) (\n    input wire clk,\n    input wire resetn,\n",
     "module datapath_unit #(\n    parameter RESET_ADDR = 0,\n    parameter RESET_ADDR1 = 0,\n    parameter HART_ID = 0\n) (\n"
     "    input wire clk,\n    input wire resetn,\n"
     "    // 现在跑的是哪个线程；1 号线程放开没有。带 _t 的是两个线程各自的那一份，给各自的地址转换用\n"
     "    input wire tid,\n    input wire run1,\n    output wire [1:0] wake,\n    output wire [63:0] satp_t,\n"
     "    output wire [63:0] mstatus_t,\n    output wire [3:0] privilege_mode_t,\n    output wire [1:0] tlb_flush_t,\n"),
    ("    input wire IRQ3,\n    input wire IRQ7,\n    input wire IRQ9,\n    input wire IRQ11,\n",
     "    input wire [1:0] IRQ3,\n    input wire [1:0] IRQ7,\n    input wire [1:0] IRQ9,\n    input wire [1:0] IRQ11,\n"),
    ("      .A1 (Rs1),\n      .A2 (Rs2),\n      .A3 (Rd),\n", "      .A1 ({tid, Rs1}),\n      .A2 ({tid, Rs2}),\n      .A3 ({tid, Rd}),\n"),
    ("  dff_kianV #(32, RESET_ADDR) PC_I (\n      resetn,\n      clk,\n      PCWrite,\n      pc_or_exception_next,\n      PC\n  );\n",
     "  wire [31:0] PC0, PC1;\n"
     "  dff_kianV #(32, RESET_ADDR) PC_I (\n      resetn,\n      clk,\n      PCWrite && !tid,\n      pc_or_exception_next,\n      PC0\n  );\n\n"
     "  dff_kianV #(32, RESET_ADDR1) PC1_I (\n      resetn && run1,\n      clk,\n      PCWrite && tid,\n      pc_or_exception_next,\n      PC1\n  );\n"
     "  assign PC = tid ? PC1 : PC0;\n"),
    ("  dff_kianV #(32, RESET_ADDR) OldPC_I (\n      resetn,\n      clk,\n      store_instr,\n      PC,\n      OldPC\n  );\n",
     "  // 上一条指令的 PC 跨着指令用：跳到没对齐的地址，要到取下一条时才陷入，报的是跳的那一条。中间夹着对面的一条指令，所以也每个线程一份\n"
     "  wire [31:0] OldPC0, OldPC1;\n"
     "  dff_kianV #(32, RESET_ADDR) OldPC_I (\n      resetn,\n      clk,\n      store_instr && !tid,\n      PC,\n      OldPC0\n  );\n\n"
     "  dff_kianV #(32, RESET_ADDR1) OldPC1_I (\n      resetn && run1,\n      clk,\n      store_instr && tid,\n      PC,\n      OldPC1\n  );\n"
     "  assign OldPC = tid ? OldPC1 : OldPC0;\n"),
    ("  wire amo_reserved;\n"
     "  dff_kianV #(1) amo_reserved_state_load_I (\n      .resetn(resetn),\n      .clk   (clk),\n      .d     (amo_buffered_data),\n"
     "      .en    (amo_set_reserved_state_load),\n      .q     (amo_reserved)\n  );\n\n"
     "  wire [31:0] amo_reserved_addr;\n"
     "  dff_kianV #(32) amo_reserved_addr_I (\n      .resetn(resetn),\n      .clk   (clk),\n      .d     (amo_buffer_addr_value),\n"
     "      .en    (amo_set_reserved_state_load && amo_buffered_data),\n      .q     (amo_reserved_addr)\n  );\n",
     "  // 核里记的预留（只决定 SC 试不试）也是每个线程一份：共用的话两个线程的 LR 与 SC 会互相冲掉\n"
     "  wire [ 1:0] amo_reserved_t;\n  wire [63:0] amo_reserved_addr_t;\n  genvar ti;\n  generate\n"
     "    for (ti = 0; ti < 2; ti = ti + 1) begin : g_rsv\n"
     "      dff_kianV #(1) amo_reserved_state_load_I (\n          .resetn(resetn),\n          .clk   (clk),\n"
     "          .d     (amo_buffered_data),\n          .en    (amo_set_reserved_state_load && tid == ti),\n"
     "          .q     (amo_reserved_t[ti])\n      );\n"
     "      dff_kianV #(32) amo_reserved_addr_I (\n          .resetn(resetn),\n          .clk   (clk),\n"
     "          .d     (amo_buffer_addr_value),\n          .en    (amo_set_reserved_state_load && amo_buffered_data && tid == ti),\n"
     "          .q     (amo_reserved_addr_t[ti*32+:32])\n      );\n    end\n  endgenerate\n"
     "  wire        amo_reserved = amo_reserved_t[tid];\n"
     "  wire [31:0] amo_reserved_addr = tid ? amo_reserved_addr_t[63:32] : amo_reserved_addr_t[31:0];\n"),
]

CSRS = """  // CSR、特权级与中断的判定每个线程一份：写与事件只给现在跑的那个线程，读出来的按线程选。
  // 1 号线程没放开时它的那一份按在复位里
  wire [ 63:0] csr_rdata_t, exception_next_pc_t;
  wire [127:0] timer_counter_t;
  wire [  1:0] exception_select_t, csr_access_fault_t;
  wire [1:0] irq1_t, irq3_t, irq5_t, irq7_t, irq9_t, irq11_t;
  generate
    for (ti = 0; ti < 2; ti = ti + 1) begin : g_csr
      wire mine = tid == ti;
      csr_exception_handler #(
          .HART_ID(ti)
      ) csr_exception_handler_I (
          .clk              (clk),
          .resetn           (resetn && (ti == 0 || run1)),
          .sysclk_mhz_q8_8  (sysclk_mhz_q8_8),
          .incr_inst_retired(incr_inst_retired && mine),
          .CSRAddr          (CSRAddr),
          .CSRop            (CSRop),
          .Rd1              (SrcA),
          .uimm             (Rs1),
          .we               (CSRwe && mine),
          .re               (CSRre && mine),
          .exception_event  (exception_event && mine),
          .mret             (mret && mine),
          .sret             (sret && mine),
          .wfi_event        (wfi_event && mine),
          .cause            (cause),
          .pc               (pc_on_exception),
          .badaddr          (badaddr),

          .privilege_mode   (privilege_mode_t[ti*2+:2]),
          .rdata            (csr_rdata_t[ti*32+:32]),
          .exception_next_pc(exception_next_pc_t[ti*32+:32]),
          .exception_select (exception_select_t[ti]),
          .csr_access_fault (csr_access_fault_t[ti]),
          .satp             (satp_t[ti*32+:32]),
          .tlb_flush        (tlb_flush_t[ti]),
          .mstatus          (mstatus_t[ti*32+:32]),
          .timer_counter    (timer_counter_t[ti*64+:64]),
          .IRQ3             (IRQ3[ti]),
          .IRQ7             (IRQ7[ti]),
          .IRQ9             (IRQ9[ti]),
          .IRQ11            (IRQ11[ti]),
          .IRQ_TO_CPU_CTRL1 (irq1_t[ti]),
          .IRQ_TO_CPU_CTRL3 (irq3_t[ti]),
          .IRQ_TO_CPU_CTRL5 (irq5_t[ti]),
          .IRQ_TO_CPU_CTRL7 (irq7_t[ti]),
          .IRQ_TO_CPU_CTRL9 (irq9_t[ti]),
          .IRQ_TO_CPU_CTRL11(irq11_t[ti]),
          .wake             (wake[ti])
      );
    end
  endgenerate
  assign privilege_mode    = tid ? privilege_mode_t[3:2] : privilege_mode_t[1:0];
  assign CSRData           = tid ? csr_rdata_t[63:32] : csr_rdata_t[31:0];
  assign exception_next_pc = tid ? exception_next_pc_t[63:32] : exception_next_pc_t[31:0];
  assign exception_select  = exception_select_t[tid];
  assign csr_access_fault  = csr_access_fault_t[tid];
  assign satp              = tid ? satp_t[63:32] : satp_t[31:0];
  assign tlb_flush         = tlb_flush_t[tid];
  assign mstatus           = tid ? mstatus_t[63:32] : mstatus_t[31:0];
  // 系统的微秒计数取 0 号线程的那一份：它不跟着 1 号的收放复位
  assign timer_counter     = timer_counter_t[63:0];
  assign IRQ_TO_CPU_CTRL1  = irq1_t[tid];
  assign IRQ_TO_CPU_CTRL3  = irq3_t[tid];
  assign IRQ_TO_CPU_CTRL5  = irq5_t[tid];
  assign IRQ_TO_CPU_CTRL7  = irq7_t[tid];
  assign IRQ_TO_CPU_CTRL9  = irq9_t[tid];
  assign IRQ_TO_CPU_CTRL11 = irq11_t[tid];

endmodule
"""

SCHED = """  wire        stall;

  wire        amo_lock, lr_read, sc_write, sc_abort, next_instr;
  wire [ 1:0] wake;
  wire [63:0] satp_t, mstatus_t;
  wire [ 3:0] privilege_mode_t;
  wire [ 1:0] tlb_flush_t;

  // 轮转：每条指令做完换另一个线程。一个线程执行了 WFI 而没有开着又挂起的中断，就记它在睡，轮转跳过它，
  // 等它的中断来了再排回去。睡着的每跳过 63 次也轮到一次：WFI 本来就许无故返回，
  // 拿它当停顿、靠轮询内存等另一个线程的程序不会被饿死。1 号没放开时只有 0 号
  reg         tid;
  reg  [ 1:0] sleep;
  reg  [ 5:0] skipped;
  wire [ 1:0] run = {run1, 1'b1};
  wire        take = run[!tid] && (!sleep[!tid] || wake[!tid] || &skipped);
  always @(posedge clk) begin
    if (!resetn) begin
      tid     <= 1'b0;
      sleep   <= 2'b00;
      skipped <= 6'd0;
    end else begin
      sleep <= (sleep | {wfi_event && tid, wfi_event && !tid}) & ~wake & run;
      if (next_instr) begin
        tid     <= take ? !tid : tid && run1;
        skipped <= (take || !run[!tid]) ? 6'd0 : skipped + 6'd1;
      end
    end
  end
"""

MMU = """  // 地址转换每个线程一份，各有各的 satp 与 TLB；请求只给现在跑的那个线程
  wire [ 1:0] v_cpu_ready, v_mem_valid, v_stall, v_page_fault;
  wire [63:0] v_cpu_rdata, v_mem_wdata, v_fault_address;
  wire [ 7:0] v_mem_wstrb;
  wire [67:0] v_mem_addr;
  wire        m_ready;
  genvar ti;
  generate
    for (ti = 0; ti < 2; ti = ti + 1) begin : g_mmu
      sv32 #(
          .NUM_ENTRIES_ITLB(`NUM_ENTRIES_ITLB),
          .NUM_ENTRIES_DTLB(`NUM_ENTRIES_DTLB)
      ) mmu_I (
          .clk   (clk),
          .resetn(resetn && (ti == 0 || run1)),

          .cpu_valid(cpu_mem_valid && tid == ti),
          .cpu_ready(v_cpu_ready[ti]),
          .cpu_wstrb(cpu_mem_wstrb),
          .cpu_addr (cpu_mem_addr),
          .cpu_wdata(cpu_mem_wdata),
          .cpu_rdata(v_cpu_rdata[ti*32+:32]),

          .mem_valid    (v_mem_valid[ti]),
          .mem_ready    (m_ready && tid == ti),
          .mem_wstrb    (v_mem_wstrb[ti*4+:4]),
          .mem_addr     (v_mem_addr[ti*34+:34]),
          .mem_wdata    (v_mem_wdata[ti*32+:32]),
          .mem_rdata    (mem_rdata),
          .fault_address(v_fault_address[ti*32+:32]),

          .privilege_mode(privilege_mode_t[ti*2+:2]),
          .is_instruction(is_instruction),
          .tlb_flush     ((tlb_flush && tid == ti) | tlb_flush_t[ti]),
          .stall         (v_stall[ti]),
          .satp          (satp_t[ti*32+:32]),
          .mstatus       (mstatus_t[ti*32+:32]),
          .page_fault    (v_page_fault[ti])
      );
    end
  endgenerate
  assign cpu_mem_ready      = v_cpu_ready[tid];
  assign cpu_mem_rdata      = tid ? v_cpu_rdata[63:32] : v_cpu_rdata[31:0];
  assign sv32_fault_address = tid ? v_fault_address[63:32] : v_fault_address[31:0];
  assign stall              = v_stall[tid];
  assign page_fault         = v_page_fault[tid];

  wire        m_valid = v_mem_valid[tid];
  wire [ 3:0] m_wstrb = tid ? v_mem_wstrb[7:4] : v_mem_wstrb[3:0];
  wire [33:0] m_addr = tid ? v_mem_addr[67:34] : v_mem_addr[33:0];

  // LR 与 SC 的预留按物理地址记，每个线程一条，做法同 to2610-smp 的仲裁：
  //   LR  记下这个线程读的那个字（取页表的那几次读也会记进来，后面真正的那一次读盖掉它们）
  //   写  另一个线程预留着同一个字，那条预留作废
  //   SC  预留已经作废、或写的不是预留的那个字，这一笔不上总线，晚一拍回应答并告诉状态机没写成；SC 之后预留一律放掉
  reg         rv0, rv1, nack;
  reg  [31:0] ra0, ra1;
  wire [31:0] word = m_addr[33:2];
  wire        wr = |m_wstrb;
  wire        held = tid ? rv1 && ra1 == word : rv0 && ra0 == word;
  wire        scw = m_valid && sc_write && wr;
  wire        drop = scw && !held;
  wire        done = m_valid && (drop ? nack : mem_ready);
  wire        good = done && (drop || !access_fault);
  always @(posedge clk) begin
    if (!resetn) begin
      rv0  <= 1'b0;
      rv1  <= 1'b0;
      ra0  <= 32'h0;
      ra1  <= 32'h0;
      nack <= 1'b0;
    end else begin
      nack <= drop && !nack;
      if (good && lr_read && !wr) begin
        if (tid) begin
          rv1 <= 1'b1;
          ra1 <= word;
        end else begin
          rv0 <= 1'b1;
          ra0 <= word;
        end
      end
      if (good && wr && !drop) begin
        if (tid && ra0 == word) rv0 <= 1'b0;
        if (!tid && ra1 == word) rv1 <= 1'b0;
      end
      if (good && scw) begin
        if (tid) rv1 <= 1'b0;
        else rv0 <= 1'b0;
      end
    end
  end
  assign m_ready   = drop ? nack : mem_ready;
  assign sc_abort  = drop && nack;
  assign mem_valid = m_valid && !drop;
  assign mem_wstrb = m_wstrb;
  assign mem_addr  = m_addr;
  assign mem_wdata = tid ? v_mem_wdata[63:32] : v_mem_wdata[31:0];

endmodule
"""

TOP = [
    ("    parameter RESET_ADDR = 0,\n    parameter HART_ID = 0,\n",
     "    parameter RESET_ADDR = 0,\n    parameter RESET_ADDR1 = 32'h8000_0000,\n    parameter HART_ID = 0,\n"),
    ("    input  wire        IRQ3,\n    input  wire        IRQ7,\n    input  wire        IRQ9,\n    input  wire        IRQ11,\n",
     "    input  wire [ 1:0] IRQ3,\n    input  wire [ 1:0] IRQ7,\n    input  wire [ 1:0] IRQ9,\n    input  wire [ 1:0] IRQ11,\n"),
    ("    output wire        icache_flush,\n    output wire        amo_lock,\n    output wire        lr_read,\n"
     "    output wire        sc_write,\n    input  wire        sc_abort\n);\n",
     "    output wire        icache_flush,\n    // 1 号线程放开没有；收着的时候只有 0 号线程在跑\n    input  wire        run1\n);\n"),
    ("  wire        stall;\n", SCHED),
    ("      .sc_abort         (sc_abort),\n", "      .sc_abort         (sc_abort),\n      .next_instr       (next_instr),\n"),
    ("      .RESET_ADDR(RESET_ADDR),\n      .HART_ID   (HART_ID)\n",
     "      .RESET_ADDR (RESET_ADDR),\n      .RESET_ADDR1(RESET_ADDR1),\n      .HART_ID    (HART_ID)\n"),
    ("  ) datapath_unit_I (\n      .clk            (clk),\n      .resetn         (resetn),\n",
     "  ) datapath_unit_I (\n      .clk            (clk),\n      .resetn         (resetn),\n"
     "      .tid             (tid),\n      .run1            (run1),\n      .wake            (wake),\n      .satp_t          (satp_t),\n"
     "      .mstatus_t       (mstatus_t),\n      .privilege_mode_t(privilege_mode_t),\n      .tlb_flush_t     (tlb_flush_t),\n"),
]

SOC = [
    ("  wire        a_valid, a_ready, a_fault, a_instr;\n  wire [ 3:0] a_wstrb;\n  wire [33:0] a_addr;\n  wire [31:0] a_wdata;\n"
     "  wire        b_valid, b_ready, b_fault, b_instr, b_irq3, b_irq7, b_go, b_run, b_meip;\n"
     "  wire        a_lock, a_lr, a_sc, a_scfail, b_lock, b_lr, b_sc, b_scfail;\n"
     "  wire [ 3:0] b_wstrb;\n  wire [33:0] b_addr;\n  wire [31:0] b_wdata;\n",
     "  wire        b_irq3, b_irq7, b_run, b_meip;\n"),
]

CORE = """  // 一个核、两个硬件线程，直接接片上总线，不要仲裁。软件看到的还是 0 号与 1 号两个 hart：
  // 各有各的 CLINT，外部中断进 0 号，1 号有核间那一页的门铃；1 号由那一页的 RUN 放开，从 SDRAM 起步
  kianv_harris_mc_edition #(
      .RESET_ADDR      (`RESET_ADDR),
      .RESET_ADDR1     (32'h8000_0000),
      .NUM_ENTRIES_ITLB(`NUM_ENTRIES_ITLB),
      .NUM_ENTRIES_DTLB(`NUM_ENTRIES_DTLB)
  ) kianv_I (
      .clk            (clk),
      .resetn         (resetn_soc),
      .sysclk_mhz_q8_8(sysclk_mhz_q8_8),
      .mem_ready      (cpu_mem_ready),
      .mem_valid      (cpu_mem_valid),
      .mem_wstrb      (cpu_mem_wstrb),
      .mem_addr       (cpu_mem_addr_phy),
      .mem_wdata      (cpu_mem_wdata),
      .mem_rdata      (cpu_mem_rdata),
      .access_fault   (access_fault_ready),
      .timer_counter  (timer_counter),
      .is_instruction (is_instruction),
      .icache_flush   (icache_flush),
      .run1           (b_run),
      .IRQ3           ({b_irq3, IRQ3}),
      .IRQ7           ({b_irq7, IRQ7}),
      .IRQ9           ({1'b0, irq_ctx1_w}),
      .IRQ11          ({b_meip, irq_ctx0_w}),
      .PC             ()
  );
"""

AMP = [
    ("//   0x00 ID      只读，0x534D5031（\"SMP1\"）\n", "//   0x00 ID      只读，0x534D5431（\"SMT1\"）\n"),
    ("        bus_rdata_o <= sel == 3'd0 ? 32'h534D_5031 :\n", "        bus_rdata_o <= sel == 3'd0 ? 32'h534D_5431 :\n"),
]


def edit(name: str, pairs, cuts=()):
    a = b = (root / name).read_text(encoding="utf-8")
    for x, y in pairs:
        assert b.count(x) == 1, (name, b.count(x), x[:60])
        b = b.replace(x, y)
    for head, tail, new in cuts:
        assert b.count(head) == 1, (name, head[:60])
        i = b.index(head)
        j = b.index(tail, i) + len(tail)
        b = b[:i] + new + b[j:]
    return list(difflib.unified_diff(a.splitlines(keepends=True), b.splitlines(keepends=True), "a/src/" + name, "b/src/" + name))


out = edit(K + "register_file.v", REGFILE)
out += edit(K + "main_fsm.v", FSM)
out += edit(K + "control_unit.v", CONTROL)
out += edit(K + "csr_exception_handler.v", CSR)
out += edit(K + "datapath_unit.v", DATAPATH,
            [("  csr_exception_handler #(\n      .HART_ID(HART_ID)\n  ) csr_exception_handler_I (", "endmodule\n", CSRS)])
out += edit(K + "kianv_harris_mc_edition.v", TOP, [("  sv32 #(\n", "endmodule\n", MMU)])
out += edit("amp_ctl.v", AMP)
out += edit("soc.v", SOC,
            [("  kianv_harris_mc_edition #(\n      .RESET_ADDR      (`RESET_ADDR),", "      .fault  (access_fault_ready)\n  );\n", CORE)])
sys.stdout.writelines(out)
