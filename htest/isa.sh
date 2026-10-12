#!/usr/bin/env bash
# riscv-tests 在两个线程上各跑：体系结构状态每个线程一份，哪一份都要过一遍，而且要在两个线程轮着跑的时候过。
# 跑法同黑盒仓的 htest/isa.sh（程序放进 SDRAM、测试台盯 tohost），只是 Flash 里的复位入口换成 htest/isa/go.S，分三种：
#   both  0 号线程跑测试，1 号放开后被测试环境挡在入口转圈：两个线程一人一条指令地轮
#   nap   1 号线程跑测试，0 号放开它之后睡着
#   busy  1 号线程跑测试，0 号放开它之后不停地改自己的寄存器、CSR 与内存
# 1 号线程上测试环境的头文件换成 htest/isa/env1 的那一份（上游的把 0 号以外的 hart 挡住，那里反过来）。
# 用法：isa.sh <输出目录> <编好的 Vtb 所在目录> <gf180mcu-kianv-rv32ima-sv32 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
SIM=$(realpath "$2")
K=$(realpath "$3")
X=${CROSS:-riscv64-unknown-elf-}
R=$K/third_party/riscv-tests
[ -f "$R/env/p/link.ld" ] || { echo "riscv-tests 的子模块没取：git submodule update --init --recursive"; exit 1; }
mkdir -p "$O"

# 不适用的不跑：Zacas 不是 A 本身；非对齐访存、PMP、调试触发器 KianV 都没做
SKIP=" rv32ua-p-amocas_w rv32ua-p-amocas_d rv32ui-p-ma_data rv32mi-p-pmpaddr rv32mi-p-breakpoint "
MODES=(both nap busy)

for m in 0 1 2; do
  "${X}gcc" -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -DMODE=$m -Wl,-Ttext=0x20100000 -o "$O/go$m.elf" htest/isa/go.S
  "${X}objcopy" -O binary "$O/go$m.elf" "$O/go$m.bin"
done

n=0; bad=0
# $1 哪一种（0、1、2），$2 源文件，$3 用例名
try() {
  local m=$1 t=$2 b=$3 e="$O/${MODES[$1]}-$3" env=()
  [[ $SKIP == *" $b "* ]] && return
  # ONLY="<哪一种> <用例名>" 时只跑这一个（埋错用）
  [ -z "${ONLY:-}" ] || [ "$ONLY" = "${MODES[$m]} $b" ] || return 0
  # mcsr 的第三项测的就是 mhartid 读到 0，1 号线程上不适用
  [ "$m" != 0 ] && [ "$b" = rv32mi-p-mcsr ] && return
  [ "$m" = 0 ] || env=(-I htest/isa/env1)
  n=$((n + 1))
  # -fno-pic：Linux 工具链默认位置无关，env 里的 la 会出 GOT 重定位
  "${X}gcc" -march=rv32ima_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
    -nostdlib -nostartfiles -fno-pic -no-pie "${env[@]}" -I "$R/env/p" -I "$R/isa/macros/scalar" \
    -T "$R/env/p/link.ld" "$t" -o "$e.elf"
  "${X}objcopy" -O binary "$e.elf" "$e.bin"
  if ! "$SIM/Vtb" +flash="$O/go$m.bin@0x100000" +sdram="$e.bin@0" \
    +tohost="0x$("${X}nm" "$e.elf" | awk '$3 == "tohost" {print $1}')" +max=20000000 > "$e.log" 2>&1; then
    echo "FAIL ${MODES[$m]} $b：$(grep -a 'tohost' "$e.log" | tail -n 1)"
    bad=$((bad + 1))
  fi
}
for m in 0 1 2; do
  for s in rv32ui rv32um rv32ua rv32mi rv32si; do
    for t in "$R"/isa/$s/*.S; do
      try $m "$t" "$s-p-$(basename "$t" .S)"
    done
  done
  # 黑盒仓自己补的定向测试，同一个环境、同一种跑法
  for t in "$K"/htest/isa/*.S; do
    try $m "$t" "own-p-$(basename "$t" .S)"
  done
done

echo "三种各一遍共跑 $n 次，$bad 次不过，不适用 $(wc -w <<< "$SKIP") 个（1 号线程上另有 mcsr）"
[ "$n" -gt 0 ] && [ "$bad" = 0 ]
