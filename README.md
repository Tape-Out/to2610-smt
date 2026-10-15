# to2610-smt

A hyper-threaded chip for the ECOS 2610 shuttle: one KianV core, two hardware threads. The core keeps a single state machine, datapath and memory port, and one copy of the architectural state per thread. Software sees the two harts of [`to2610-smp`](https://github.com/Tape-Out/to2610-smp), and that chip's two-hart Linux image boots here unchanged.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20OR%20MulanPSL--2.0-blue)

The core is upstream's KianV, its submodule untouched, taken from [`gf180mcu-kianv-rv32ima-sv32`](https://github.com/Tape-Out/gf180mcu-kianv-rv32ima-sv32); the peripherals and the pads are those of [`to2610-kvc`](https://github.com/Tape-Out/to2610-kvc); the second CLINT and the inter-hart page come from [`to2610-amp`](https://github.com/Tape-Out/to2610-amp) by way of `to2610-smp`. This repository adds one patch, `patch/smt.patch`, which `patch/mkpatch.py` regenerates: the two cores and the arbiter of `to2610-smp` become one core with two threads.

The functions, the registers, the pad table, the tests and the limits are in [`docs/流片说明.md`](docs/流片说明.md); the tape-out report is generated from that file.

## One core, two threads

KianV is a multi-cycle core: an instruction takes some ten cycles from fetch to write-back, and the state machine returning to fetch marks its end. The thread changes only there, so whatever lives inside one instruction is shared, and only what survives from one instruction to the next exists twice:

| State | Per thread |
|:--:|:--:|
| integer registers | one register file of 64 entries, the thread number as the top address bit |
| PC, and the PC of the previous instruction | two registers each; the second is what a misaligned jump reports when it traps at the next fetch |
| CSRs, privilege mode, interrupt selection | the module instantiated twice; writes and events go to the running thread only |
| address translation | `satp` and both TLBs, the module instantiated twice |
| LR reservation | one per thread in the core, and a table of two physical addresses at the memory port |

Because an instruction is never interrupted by the other thread, the AMOs are atomic as they are. A store by one thread to the word the other has reserved cancels that reservation, and an SC whose reservation is gone never reaches the bus.

## Sleeping threads

Upstream treats WFI as a no-op. Here a thread that executes WFI with no enabled interrupt pending is marked asleep and the rotation skips it, so the other thread runs every instruction, close to single-core speed. A pending interrupt puts the sleeper back at once. A sleeper also gets a turn after being skipped 63 times, since WFI may return spuriously: a program that uses it as a pause while polling memory still makes progress.

## Starting the second thread

Only hart 0 runs after reset, exactly as `to2610-kvc` does. Writing 1 to `RUN` at `0x4004_0004` releases hart 1; it starts at `0x8000_0000`, where the boot loader has put the payload, so both harts enter the same code and part ways on `mhartid`. Writing 0 takes it back.

Each hart has its own CLINT, at `0x0200_0000` and `0x0300_0000`; an inter-processor interrupt is a write to the other hart's `msip`.

## Testing and tape-out

```console
$ ran run to2610-smt src                  # assemble build/src
$ ran test to2610-smt                     # the chip tests, then the planted faults
$ ran asic to2610-smt                     # to2610_smt.v, ecc at 50 MHz, report.json
```

`chip` runs on the Verilog file that goes to the shuttle.

| Test | What |
|:--:|:--:|
| `hello`, `periph`, `isa`, `arch-test`, `boot` | the tests of `to2610-kvc` unchanged: with hart 1 held, this chip is that one |
| `rtos`, `image`, `linux` | FreeRTOS and the single-core Linux image of `to2610-kvc` on hart 0: the image first boots in QEMU, then from flash on this chip to a shell, relayed over CI jobs |
| `image-smp`, `linux-smp` | the two-hart Linux image of `to2610-smp` unchanged: the firmware releases hart 1 at cold boot and the SMP kernel brings it up; both CPUs in `/proc/cpuinfo`, `apptest`, two busy loops on two CPUs, IPIs counted on both; a second relay |
| `threads` | riscv-tests on each thread, 238 runs, in three rotations: hart 0 under test with hart 1 spinning, hart 1 under test with hart 0 asleep, hart 1 under test with hart 0 rewriting its own registers, CSRs and memory |
| `smt` | one program on both harts: a shared counter that must lose updates without atomics and must not with `amoadd`, a spinlock or LR/SC; a page table for each thread, the same virtual address on different physical pages; reservations across threads; interrupts both ways; sleep, wake-up and polling through WFI; hart 1 taken back and released; hart 1 reads the same `time` as the CLINT, its own counter being replaced by hart 0's |

`design-faults` makes one piece of per-thread state shared, or removes one rule of the rotation or the reservations, twelve faults in turn; each must turn its line of the tests red.

## License

任选其一：

- [MIT](LICENSE-MIT)
- [Apache 2.0](LICENSE-APACHE)
- [木兰宽松许可证 第2版](LICENSE-MULAN)

`SPDX-License-Identifier: MIT OR Apache-2.0 OR MulanPSL-2.0`

The upstream sources keep their own licence: Apache-2.0.

除非另行说明，你提交的贡献按上述三者同时授权，不附加其他条件。
