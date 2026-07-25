# nn_fc_quantized

`nn_fc_quantized` performs the same 1024-input, 64-output fully connected-layer operation as `nn_fc`, while replacing the floating-point PE datapath with the signed integer MAC, wide accumulator, requantization, and Float-conversion modules in `QuantizedMath.bsv`.

The project keeps the original UART and SDRAM data flow. The Host still sends 32-bit Float weights and inputs, FPGA logic quantizes them once before the 16-PE array, each PE accumulates one quantized dot product, and the completed output is requantized and converted back to Float before transmission.

## Precision selection

`QUANTIZED_WIDTH` selects one statically specialized datapath at compile time.

| Width | Input/weight scale | Output scale | Requantization | Accumulator |
|---|---:|---:|---:|---:|
| INT4 | 2.0 | 512.0 | `acc >> 7` with rounding | 32-bit |
| INT8 | 0.125 | 32.0 | `acc >> 11` with rounding | 32-bit |
| INT16 | 1/1024 | 0.25 | `acc >> 18` with rounding | 64-bit |

All modes use signed symmetric quantization with zero-point 0. INT8 is the default.

```bash
make runsim PROJECT=nn_fc_quantized BOARD=ulx3s-85f QUANTIZED_WIDTH=8
make synth PROJECT=nn_fc_quantized BOARD=ulx3s-85f QUANTIZED_WIDTH=8
make host PROJECT=nn_fc_quantized QUANTIZED_WIDTH=8
```

Hardware and Host software must use the same `QUANTIZED_WIDTH`. The Host generates deterministic signed values aligned to the selected input scale, compares FPGA output against an integer quantized golden model, and separately reports the error relative to the floating-point fully connected layer.
