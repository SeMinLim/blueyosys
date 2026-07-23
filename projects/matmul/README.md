# matmul

`matmul` is a baseline 4x4 `SimpleFloat` matrix-multiplication project for studying Bluespec pipelines, operator utilization, parallelism, and FPGA performance with blueYosys.

## Data layout

The Host streams matrix A followed by matrix B in transposed layout. The kernel computes:

```text
C[i][j] = sum(A[i][k] * B_T[j][k]),  k = 0..3
```

`B_T` stores each original column of B as one sequential row. This intentional cache-aware layout lets the kernel consume both operands as row-wise streams while producing `C = A x B`.

## Baseline architecture

The design uses one pipelined `SimpleFloat` multiplier and one pipelined `SimpleFloat` adder. Its serialized accumulation and single-operator datapath are intentionally retained as a baseline for studying loop reordering, pipeline utilization, parallel operators, timing, and resource usage.

Input and output use fixed-order little-endian UART streams without opcodes: sixteen floats for A, sixteen floats for `B_T`, and sixteen result floats.

## Build and evaluate

```bash
make runsim PROJECT=matmul BOARD=ulx3s-85f
make synth PROJECT=matmul BOARD=ulx3s-85f
```

Simulation output is written to `projects/matmul/system.log`. Resource utilization and routed clock frequency are reported in `projects/matmul/build/mkTop.utilization.rpt`.
