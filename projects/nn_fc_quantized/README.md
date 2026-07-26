# nn_fc_quantized

`nn_fc_quantized` performs the same 1024-input, 64-output fully connected-layer operation as `nn_fc`, but quantizes and packs operands on the Host before sending them to the FPGA.

## Packed runtime precision

| Width | Values/word | Input groups | Input/weight scale | Requantization | Output scale | Payload vs. FP32 |
|---|---:|---:|---:|---:|---:|---:|
| INT4 | 4 | 256 | 2.0 | `acc >> 7` | 512.0 | 1/8 |
| INT8 | 2 | 512 | 0.125 | `acc >> 11` | 32.0 | 1/4 |
| INT16 | 1 | 1024 | 1/1024 | `acc >> 18` | 0.25 | 1/2 |

All modes use signed symmetric quantization with zero-point 0. The Host retains the same sparse data pattern used by `nn_fc`, uses signed floating-point values to exercise the signed datapath, and quantizes them before packing. Set the runtime width in `cpp/main.cpp`; the same Host source sends it to Bluesim and the physical FPGA.

```cpp
const int quantizedWidth = 8;
```

## Data layout and execution

The Host quantizes both operands, packs them into 16-bit words, and stores weights in group-major order:

```text
weightPack[groupIdx][outputIdx]
```

Each group contains 64 consecutive 16-bit weight words, one for every output. The FPGA reads one packed input word, issues one 64-word SDRAM burst, and reuses that input word across all 64 outputs. `NnFc.bsv` then executes four INT4, two INT8, or one INT16 multiplication per packed operation, reduces the lane products, and updates a shared bank of 64 wide accumulators.

Completed accumulators are requantized to signed integers and returned in the same six-byte result format used by `nn_fc`: input index, output index, and a 32-bit payload. The Host dequantizes the payload and compares it with both the integer golden model and the floating-point FC result. It also reports payload size, actual UART transfer size, and quantization error.

Cycle reporting remains identical to `nn_fc`:

```text
Emitting 256 elements over N cycles
```

```bash
make runsim PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make synth PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make host PROJECT=nn_fc_quantized
projects/nn_fc_quantized/cpp/obj/main /dev/ttyUSB0
```
