#!/usr/bin/env bash
# 拼出这一颗的源码树 build/src：先让 to2610-smp 拼好它的那一份（to2610-kvc 加第二个核、它的 CLINT、核间那一页，核带编号），
# 套上 patch/smt.patch：两个核加仲裁换成一个核、两个硬件线程。上游子模块不动。
# 用法：setup.sh <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-amp 仓> <to2610-smp 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
K=$(realpath "$1")
M=$(realpath "$2")
S=$(realpath "$3")
rm -rf build/src
mkdir -p build
bash "$S/htest/setup.sh" "$K" "$M" > /dev/null
cp -r "$S/build/src" build/src
patch -s -p1 -d build < patch/smt.patch
rm build/src/smp_arb.v
echo "build/src：$(find build/src -name '*.v' -o -name '*.sv' | wc -l) 个源文件"
