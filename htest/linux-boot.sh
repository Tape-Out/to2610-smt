#!/usr/bin/env bash
# Linux 在这一颗上从 Flash 起到 shell 要仿几个小时，托管机的一个作业放不下，分几棒跑（做法同 to2610-soc）。
# 整片测试把编好的仿真器、拼好的 Flash 镜像与脚本放在 build/linux-run；每一棒跑满 LINUX_LEG 秒就把断点存在那里，
# 下一棒接着同一份脚本往下走。走完了放一个 done，后面的棒直接收工。
# 用法：linux-boot.sh <输出目录> <to2610-kvc 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
L=$(realpath "$2")
R=$PWD/build/linux-run
rm -rf "$O"
mkdir -p "$O"
what="to2610-kvc 的镜像原样在这一颗上从 Flash 起到 shell，跑它的那组命令：1 号线程没放开，0 号线程上起的是一份单核的 Linux"
if [ -f "$R/done" ]; then
  echo "前面的棒已经走完"
  python3 "$L/htest/junit.py" "$O/results.xml" "linux=0:0:$what（前面的棒走完的）"
  exit 0
fi
for f in Vtb linux.flash linux.script; do
  [ -s "$R/$f" ] || { echo "build/linux-run 里没有 $f：先跑整片测试"; exit 1; }
done
chmod +x "$R/Vtb"
from=()
[ -s "$R/ckpt" ] && from=(+restore="$R/ckpt")
t0=$SECONDS
rc=0
"$R/Vtb" +flash="$R/linux.flash@0" +script="$R/linux.script" +pace=600000 +max=20000000000 +beat=1000000000 \
  "${from[@]}" +stop="${LINUX_LEG:-16200}s@$R/next" > "$O/linux.log" 2> "$O/linux.err" || rc=$?
tail -n 3 "$O/linux.err"
cat "$O/linux.log" >> "$R/console.log"
if [ $rc = 0 ] && grep -q '^停在这里' "$O/linux.err"; then
  mv "$R/next" "$R/ckpt"
  mv "$R/next.tb" "$R/ckpt.tb"
  echo "这一棒跑满了时限，断点交给下一棒"
  python3 "$L/htest/junit.py" "$O/results.xml" "linux-leg=0:$((SECONDS - t0)):这一棒跑满时限，断点交给下一棒"
  exit 0
fi
[ $rc = 0 ] && touch "$R/done"
python3 "$L/htest/junit.py" "$O/results.xml" "linux=$rc:$((SECONDS - t0)):$what"
cp "$R/console.log" "$O/console.log"
exit $rc
