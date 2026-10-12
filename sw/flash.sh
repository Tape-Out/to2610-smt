#!/usr/bin/env bash
# 把 Flash 镜像烧进板上的 SPI Flash，用 flashrom。
# 镜像的格式与 to2610-kvc 的相同：引导程序与打包取它仓里的 sw/（pack.py、boot），载荷是两个线程进同一个入口的程序。
# 烧的时候按住芯片的复位：复位期间它一根脚都不驱动，Flash 的四根线才归编程器。写完自动回读比对，松开复位就从它启动。
# 用法：flash.sh <flash.bin> [flashrom 的编程器]
#   不给              CH341A
#   ft2232_spi:type=232H                           FT232H 模块
#   linux_spi:dev=/dev/spidev0.0,spispeed=8000     树莓派的 SPI0
set -euo pipefail
f=${1:?要烧的镜像}
p=${2:-ch341a_spi}
t=$(mktemp)
trap 'rm -f "$t"' EXIT
# flashrom 要镜像与芯片一样大，后面补 0xff 到 16 MiB
python3 - "$f" "$t" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[2]).write_bytes(d + b"\xff" * ((16 << 20) - len(d)))
PY
flashrom -p "$p" -w "$t"
