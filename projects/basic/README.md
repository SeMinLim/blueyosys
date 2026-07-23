# basic

`basic` is the introductory blueYosys project for learning host-to-FPGA UART streaming, external SDRAM access, and simple floating-point arithmetic in Bluespec SystemVerilog.

## Data flow

```text
Host C++
  -> UART byte stream
  -> A, B, C (three 32-bit floats)
  -> ULX3S SDRAM write and read-back
  -> SimpleMac: A x B + C
  -> UART byte stream
  -> read-back A, B, C, and the MAC result
```

Each transaction has a fixed format and does not use an opcode.

```text
Input:  A[4 bytes], B[4 bytes], C[4 bytes]
Output: A[4 bytes], B[4 bytes], C[4 bytes], result[4 bytes]
```

All 32-bit values are transferred little-endian. Each input float is split into two 16-bit words, written to SDRAM addresses 0 through 5, and read back before the MAC operation begins.

## Hardware modules

- `HwMain.bsv` receives and serializes UART data, drives the SDRAM user interface, and connects the memory path to the MAC pipeline.
- `SimpleMac.bsv` implements the non-fused operation `A x B + C` with `mkFloatMult` followed by `mkFloatAdd`.
- `Mult18x18D` wraps the ECP5 18x18 hard multiplier with a pipelined Bluespec `put/get` interface. `SimpleFloat` uses this backend for significand multiplication, so synthesis maps the multiply to the ECP5 `MULT18X18D` resource instead of a large LUT multiplier.
- `SimpleFloat` reduces the floating-point significand to 18 bits to match the ECP5 multiplier. This lowers logic and routing cost, but it is not a complete IEEE-754 implementation: subnormal values, NaN, infinity, full rounding behavior, and fused multiply-add semantics are not supported.

This design keeps the complete path visible while reusing the board-level UART, clock-domain crossing, PLL, and SDRAM controller supplied by blueYosys.

## Build and run

```bash
make synth PROJECT=basic BOARD=ulx3s-85f
make host PROJECT=basic
make program PROJECT=basic BOARD=ulx3s-85f
projects/basic/cpp/obj/main /dev/ttyUSB0
```

Run the same host-driven test through Bluesim with:

```bash
make runsim PROJECT=basic BOARD=ulx3s-85f
```

The host application executes three deterministic transactions and checks both the SDRAM read-back values and the MAC result. After synthesis, `projects/basic/build/mkTop.utilization.rpt` should report one `MULT18X18D` resource.
