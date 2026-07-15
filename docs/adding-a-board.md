# Adding a board

1. Create `boards/<board>/board.mk`, `bsv/`, `rtl/`, and `constraints/`.
2. Put device-family primitives in `platforms/<family>/`; do not duplicate them
   per board.
3. Define the common/platform/board BSV directories, RTL directories,
   constraints, top sources/modules, `BOARD_READY`, and the direct toolchain
   variables consumed by `mk/project.mk`:
   `BOARD_YOSYS_SYNTH`, `BOARD_PNR_TOOL`, `BOARD_PNR_FLAGS`,
   `BOARD_PACK_TOOL`, `BOARD_PACK_FLAGS`, and the optional programmer defaults.
4. Keep `BOARD_READY := 0` until synthesis, timing, programming, UART, and any
   external memory interfaces have been tested on hardware.
5. Run `make lint`, inspect `make -C projects/test print-config BOARD=<board>`,
   then build a small project with `make synth PROJECT=test BOARD=<board>`.

Board support must call the family tools directly. A package-manager or build
wrapper may be used to install those tools, but it must not be required by the
repository build interface.
