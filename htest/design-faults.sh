#!/usr/bin/env bash
# 设计这一层的变异（十二处）：把「每个线程一份」的某一样改成共用，或把轮转、预留里的一条规矩去掉，重出 .v，
# 两个线程一起跑的那一段（htest/smt）里管这一处的那一句要红；管不到的由某一个 riscv-tests 用例来红。
# 脚本里的 expect 都拿掉、只留 done，让程序跑到底，看是哪几句红了；跑到一半卡住、该红的那一句还没报 ok，也算抓到。
# 在临时的工作区里做（别的仓软链接过来，本仓拷一份），不动真的仓。
# 用法：design-faults.sh <输出目录> <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-kvc 仓>      FAULTS=名字,名字 只跑表里的这几条
set -u
cd "$(dirname "$0")/.."
here=$PWD
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
rm -rf "$O"
mkdir -p "$O/ws/to2610-smt"
# 照这次息壤的搜索路径去链：流水线上各个依赖不在本仓旁边
for r in $(grep -o -- '-p [^ ]*' <<< "$XIRANG" | cut -c4-) "$here/.."; do
  for d in "$r"/*/; do
    n=$(basename "$d")
    [ "$n" = to2610-smt ] || [ -e "$O/ws/$n" ] || ln -s "$(realpath "$d")" "$O/ws/$n"
  done
done
tar cf - --exclude=build --exclude=.git . | tar xf - -C "$O/ws/to2610-smt"
RAN="${XIRANG%% -p *} -p $O/ws"
R=$O/ws/to2610-smt

make -s -C "$L/sw/boot" O="$O/boot" || exit 1
make -s -C htest/smt O="$O/smt" || exit 1
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/smt/smt.bin" "$O/smt.flash" > /dev/null || exit 1
echo "expect done" > "$O/script"

# 名字~sed 表达式（改的都是 patch/smt.patch）~跑什么~该红的那一句（* 是哪一句红都算）。表达式里不能出现分隔用的那个波浪号。
# 跑什么：smt 是两个线程一起的那一段；isa 后面跟「哪一种 用例名」，是那一个 riscv-tests 用例
TABLE='regbank~s/\.A1 ({tid, Rs1}),/.A1 ({1'"'"'b0, Rs1}),/~smt~*
pc~s/      PCWrite \&\& !tid,/      PCWrite,/~smt~*
oldpc~s/      store_instr \&\& !tid,/      store_instr,/~isa both rv32mi-p-ma_fetch~ma_fetch
csr~s/      wire mine = tid == ti;/      wire mine = 1'"'"'b1;/~smt~*
irq~s/          \.IRQ3             (IRQ3\[ti\]),/          .IRQ3             (IRQ3[0]),/~smt~ipi
satp~s/          \.satp          (satp_t\[ti\*32+:32\]),/          .satp          (satp_t[31:0]),/~smt~vm
kill~s/        if (tid \&\& ra0 == word) rv0 <= 1.b0;/        if (1'"'"'b0) rv0 <= 1'"'"'b0;/~smt~kill
drop~s/  wire        drop = scw \&\& !held;/  wire        drop = 1'"'"'b0;/~smt~kill
apart~s/          \.en    (amo_set_reserved_state_load \&\& amo_buffered_data \&\& tid == ti),/          .en    (amo_set_reserved_state_load \&\& amo_buffered_data),/~smt~apart
nap~s/      sleep <= (sleep | {wfi_event \&\& tid, wfi_event \&\& !tid}) \& .wake \& run;/      sleep <= 2'"'"'b00;/~smt~nap
wake~s/  assign wake = |(mie \& mip_current);/  assign wake = 1'"'"'b0;/~smt~wake
poll~s/ || \&skipped);/);/~smt~poll'

# 出 .v、编仿真器、跑，回哪几句红了（空格隔开）；smt 那一段没跑到 done 的后面跟 stuck 与报了 ok 的那几句（ok:名字）
one() {
  local C=$1 prog=$2 top stuck=
  rm -rf "$C" && mkdir -p "$C"
  (cd "$R" && $RAN asic to2610-smt --no-run -o "$C/asic" > "$C/asic.log" 2>&1) || { echo "出 .v 没成：$(tail -n 2 "$C/asic.log" | tr '\n' ' ')"; return 1; }
  top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$C/asic/report.json")
  python3 "$L/htest/shim.py" "$C/asic/report.json" > "$C/tb.v"
  bash "$K/htest/sim.sh" "$C/sim" "$C/tb.v" "$C/asic/$top.v" > "$C/sim.log" 2>&1 || { echo "仿真器没编成"; return 1; }
  if [ "$prog" = smt ]; then
    "$C/sim/Vtb" +flash="$O/smt.flash@0" +script="$O/script" +max=60000000 > "$C/run.log" 2> "$C/run.err" || stuck=1
    # 判词是「名字 ok／BAD 数」，名字可以是两个词：取 BAD 前面的那个词
    tr -d '\r' < "$C/run.log" | awk '{for (i = 2; i <= NF; i++) if ($i == "BAD") printf "%s ", $(i - 1)}'
    [ -z "$stuck" ] || { printf 'stuck '; tr -d '\r' < "$C/run.log" | awk '{for (i = 2; i <= NF; i++) if ($i == "ok") printf "ok:%s ", $(i - 1)}'; }
  else
    ONLY=${prog#isa } bash htest/isa.sh "$C/isa" "$C/sim" "$K" > "$C/run.log" 2>&1 || true
    grep -q '共跑 1 次' "$C/run.log" || { echo "那一个用例没跑起来"; return 1; }
    grep -a '^FAIL' "$C/run.log" | sed -e 's/.*-p-//' -e 's/：.*//' | tr '\n' ' '
  fi
}

got=$(one "$O/clean" smt)
rc=$?
if [ $rc -ne 0 ] || [ -n "$got" ]; then
  echo "原样的没过：$got"
  exit 1
fi
echo "原样的 smt 一段：$(tr -d '\r' < "$O/clean/run.log" | grep -ac ' ok ') 句都是 ok"

bad=0
count=0
while IFS='~' read -r name expr prog want; do
  case ",${FAULTS:-$name}," in *",$name,"*) ;; *) continue ;; esac
  count=$((count + 1))
  sed -e "$expr" patch/smt.patch > "$R/patch/smt.patch"
  if cmp -s patch/smt.patch "$R/patch/smt.patch"; then
    echo "$name 没埋上"
    bad=1
    continue
  fi
  got=$(one "$O/mut-$name" "$prog")
  rc=$?
  cp patch/smt.patch "$R/patch/smt.patch"
  red=${got%%stuck*}
  if [ $rc -ne 0 ]; then
    echo "$name：$got"
    bad=1
  elif [ "$want" = "*" ] && { [ -n "$red" ] || [[ $got == *stuck* ]]; }; then
    echo "$name 红了：${red:-跑到一半卡住}"
  elif [ "$want" != "*" ] && grep -qw -- "$want" <<< "$red"; then
    echo "$name 红了：$red"
  elif [ "$want" != "*" ] && [[ $got == *stuck* ]] && ! grep -qw -- "ok:$want" <<< "$got"; then
    echo "$name 红了：跑到一半卡住，$want 那一句没报 ok"
  else
    echo "$name 改错了，$want 那一句没红（红的是：${got:-没有}）"
    bad=1
  fi
done <<< "$TABLE"
[ $bad -eq 0 ] || { echo "有改错的地方没被抓到"; exit 1; }
echo "设计的变异：原样过，$count 处改错都红在该红的那一句上"
