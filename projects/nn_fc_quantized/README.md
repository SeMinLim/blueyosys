# nn_fc_quantized

`nn_fc_quantized` performs the same 1024-input, 64-output fully connected-layer operation as `nn_fc`, while replacing the floating-point PE datapath with the signed quantized arithmetic in `QuantizedMath.bsv`.

The Host sends one runtime width byte (`4`, `8`, or `16`) before the original UART stream of 32-bit Float weights and inputs. FPGA logic contains the INT4, INT8, and INT16 quantization, MAC, requantization, and dequantization paths from `QuantizedMath.bsv`; the received width selects the matching path for the complete fully connected-layer execution.

## Runtime precision

| Host width | Input/weight scale | Output scale | Requantization | Accumulator |
|---|---:|---:|---:|---:|
| `4` | 2.0 | 512.0 | `acc >> 7` with rounding | 32-bit |
| `8` | 0.125 | 32.0 | `acc >> 11` with rounding | 32-bit |
| `16` | 1/1024 | 0.25 | `acc >> 18` with rounding | 64-bit |

All modes use signed symmetric quantization with zero-point 0. Width selection is runtime configuration and does not change the synthesized hardware.

Set the width directly in `projects/nn_fc_quantized/cpp/main.cpp`:

```cpp
const int quantizedWidth = 8;
```

The same Host source is used by Bluesim and by the FPGA Host executable, and it sends this value to the FPGA before sending weights and inputs.

```bash
make runsim PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make synth PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make host PROJECT=nn_fc_quantized
projects/nn_fc_quantized/cpp/obj/main /dev/ttyUSB0
```

The Host compares FPGA output against an integer quantized golden model and separately reports the error relative to the floating-point fully connected layer.
