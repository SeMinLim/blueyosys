# ULX3S board support

```text
boards/ulx3s/
├── 85f/          ULX3S-85F build profile
├── bsv/          top-level, PLL, and SDRAM integration
├── constraints/  shared LPF pin constraints
└── rtl/          board-specific RTL wrappers
```

Build with the concrete ULX3S-85F selector:

```sh
make synth PROJECT=basic BOARD=ulx3s-85f
```

`boards/profiles.mk` maps the public selector to `boards/ulx3s/85f/board.mk`. Reusable ECP5 arithmetic backends remain under `fpga/ecp5/`.
