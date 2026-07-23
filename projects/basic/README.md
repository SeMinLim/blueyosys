# basic

`basic` is the introductory blueYosys project for learning host-to-FPGA UART streaming, SDRAM BL1 and burst transfers, and simple floating-point arithmetic in Bluespec SystemVerilog.

## Data flow

```text
Host C++
  -> UART byte stream
  -> A, B, C (three 32-bit floats)
  -> six BL1 SDRAM writes and reads
  -> one six-word SDRAM burst write and read
  -> SimpleMac: A x B + C from the burst read-back values
  -> UART byte stream
  -> BL1 read-back, burst read-back, and the MAC result
```

Each transaction has a fixed format and does not use an opcode.

```text
Input:  A[4 bytes], B[4 bytes], C[4 bytes]
Output: BL1_A[4], BL1_B[4], BL1_C[4],
        BURST_A[4], BURST_B[4], BURST_C[4], result[4]
```

All 32-bit values are transferred little-endian and split into two 16-bit SDRAM words. The BL1 case writes and reads addresses `0` through `5` with six `req(..., wordCnt = 1)` calls. The burst case stores the same words at addresses `16` through `21`: the first write word is passed through `req(..., wordCnt = 6)`, the remaining five words use `writeBurstData()`, and one six-word read request returns the data through six `readResp` calls.

## Hardware modules

- `HwMain.bsv` receives and serializes UART data, executes the BL1 and runtime-length burst SDRAM paths, and connects the burst read-back values to the MAC pipeline.
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

The host application executes three deterministic transactions and independently checks the BL1 read-back, burst read-back, and MAC result. After synthesis, `projects/basic/build/mkTop.utilization.rpt` should report one `MULT18X18D` resource.
