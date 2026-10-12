#!/usr/bin/env bash
# 整片测试，全部跑在 ran asic 出的那份 .v 上。测试台、片外模型来自黑盒仓，引导程序与测试台的引脚包装来自 to2610-kvc。
#   hello、periph、isa、arch-test、boot  to2610-kvc 的五段原样跑：1 号线程没放开时，这一颗与单核的那一颗一样
#   threads  riscv-tests 在两个线程上各跑，三种轮法（htest/isa.sh）
#   smt    两个线程跑同一份程序：编号、四种加法、预留跨线程、核间中断、1 号的计时器、睡与醒、收回与再放开
# 用法：chip.sh <输出目录> <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-kvc 仓>。
# 已经跑过 ran asic 的，把输出目录给 CHIP_ASIC
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
rm -rf "$O"
mkdir -p "$O"
A=${CHIP_ASIC:-$O/asic}
[ -s "$A/report.json" ] || $XIRANG asic to2610-smt --no-run -o "$A"
top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$A/report.json")
python3 "$L/htest/shim.py" "$A/report.json" > "$O/tb.v"
bash "$K/htest/sim.sh" "$O/sim" "$O/tb.v" "$A/$top.v"

res=()
run() {
  local name=$1 what=$2 t0=$SECONDS rc=0
  shift 2
  "$O/sim/Vtb" "$@" > "$O/$name.log" 2> "$O/$name.err" || rc=$?
  tail -n 3 "$O/$name.err"
  res+=("$name=$rc:$((SECONDS - t0)):$what")
}

make -s -C "$K/htest/hello" O="$O/hello"
run hello "to2610-kvc 的裸机冒烟：从 Flash 就地执行，读写 SDRAM" \
  +flash="$O/hello/hello.bin@0x100000" +script="$K/htest/hello/script" +max=30000000

make -s -C "$K/htest/periph" O="$O/periph"
run periph "to2610-kvc 的外设测试：GPIO、两路 SPI 与回声从设备、计时器中断、PLIC、重启" \
  +flash="$O/periph/periph.bin@0x100000" +script="$K/htest/periph/script" +spiecho +max=30000000

t0=$SECONDS
rc=0
SIM="$O/sim" bash "$K/htest/isa.sh" "$O/isa" > "$O/isa.log" 2>&1 || rc=$?
tail -n 3 "$O/isa.log"
res+=("isa=$rc:$((SECONDS - t0)):riscv-tests 的 rv32ui、um、ua、mi、si 逐个在这份 .v 上跑（0 号线程），程序放进 SDRAM、测试台盯 tohost；79 个全过，不适用的 5 个（Zacas、硬件非对齐访存、PMP、调试触发器）不跑")

t0=$SECONDS
rc=0
SIM="$O/sim" bash "$K/htest/arch-test.sh" "$O/arch-test" > "$O/arch-test.log" 2>&1 || rc=$?
tail -n 3 "$O/arch-test.log"
res+=("arch-test=$rc:$((SECONDS - t0)):riscv-arch-test（ACT4）的 I、M、Zmmul、Zaamo、Zalrsc、Zicsr、Zifencei、Zicntr 共 71 个自检程序逐个在这份 .v 上跑（0 号线程），期望值出自 Sail 模型")

make -s -C "$L/sw/boot" O="$O/boot"
make -s -C "$L/htest/echo" O="$O/echo"
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/echo/echo.bin" "$O/echo.flash"
run boot "引导程序搬载荷并核对校验和，载荷回显串口" \
  +flash="$O/echo.flash@0" +script="$L/htest/echo/script" +max=60000000

t0=$SECONDS
rc=0
bash htest/isa.sh "$O/threads" "$O/sim" "$K" > "$O/threads.log" 2>&1 || rc=$?
tail -n 3 "$O/threads.log"
res+=("threads=$rc:$((SECONDS - t0)):riscv-tests 在两个线程上各跑，三种轮法：0 号线程跑测试、1 号在入口转圈，两个线程一人一条指令地轮；1 号线程跑测试、0 号睡着；1 号线程跑测试、0 号不停地改自己的寄存器、CSR 与内存；共 238 次")

make -s -C htest/smt O="$O/smt"
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/smt/smt.bin" "$O/smt.flash"
run smt "两个线程跑同一份程序：编号各是 0 与 1；各加两百次同一个数，直接加会丢，amoadd、amoswap 自旋锁、LR 与 SC 三种一个不丢；各开各的页表，同一个虚地址各落各的物理页；1 号写了预留的那个字 SC 写不成，写的是别的字、或只是预留了别的字，SC 照样写成；核间中断两个方向、1 号自己的计时器中断；1 号睡着时 0 号提速一倍半以上，中断一百微秒里叫得醒，拿 WFI 轮询内存也等得到；收回 1 号它就停，再放开它从头来" \
  +flash="$O/smt.flash@0" +script=htest/smt/script +max=60000000

python3 "$L/htest/junit.py" "$O/results.xml" "${res[@]}"
printf '%s\n' "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "整片测试 ${#res[@]} 段全过"
