# nn_fc_quantized

`nn_fc_quantized` performs the same 1024-input, 64-output fully connected-layer operation as `nn_fc`, while replacing the floating-point PE datapath with the signed quantized arithmetic in `QuantizedMath.bsv`.

The Host sends one runtime width byte (`4`, `8`, or `16`) before the original UART stream of 32-bit Float weights and inputs. FPGA logic quantizes the values according to that width, executes the 16-PE fully connected layer through one common INT16 operand and 64-bit accumulator datapath, applies width-specific requantization and saturation, and converts the result back to Float.

## Runtime precision

| Host width | Input/weight scale | Output scale | Requantization |
|---|---:|---:|---:|
| `4` | 2.0 | 512.0 | `acc >> 7` with rounding |
| `8` | 0.125 | 32.0 | `acc >> 11` with rounding |
| `16` | 1/1024 | 0.25 | `acc >> 18` with rounding |

All modes use signed symmetric quantization with zero-point 0. Width selection is runtime configuration and no longer changes the synthesized hardware.

```bash
make runsim PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make synth PROJECT=nn_fc_quantized BOARD=ulx3s-85f
make host PROJECT=nn_fc_quantized
```

Select the width for Bluesim through `NN_FC_WIDTH`:

```bash
NN_FC_WIDTH=4 make runsim PROJECT=nn_fc_quantized BOARD=ulx3s-85f
```

Select the width for the FPGA Host executable with the second argument:

```bash
projects/nn_fc_quantized/cpp/obj/main /dev/ttyUSB0 8
```

The Host compares FPGA output against an integer quantized golden model and separately reports the error relative to the floating-point fully connected layer.
