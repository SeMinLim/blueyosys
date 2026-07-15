# ICE40 support plan

ICE40 is intentionally represented as a non-buildable scaffold rather than a
false claim of support. To enable a concrete ICE40 board:

1. Add board constraints and a clock/reset/top wrapper under this directory.
2. Add ICE40 primitive wrappers under `platforms/ice40/`.
3. Provide a multiplier backend for designs that currently use ECP5
   `MULT18X18D` through `SimpleFloat`.
4. Define the direct Yosys, nextpnr-ice40, bitstream packer, and programmer
   settings in `board.mk`, then set `BOARD_READY := 1` after hardware validation.

The common Bluespec libraries and every design under `projects/` are already
kept independent of the ULX3S build dispatch, so this can be added without
reorganizing the applications again.
