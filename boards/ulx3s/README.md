# ULX3S board support

This board layer contains ULX3S-specific clocking, SDRAM pins, top-level
integration, constraints, programmer defaults, and RTL wrappers. ECP5
primitives shared with future ECP5 boards live under `platforms/ecp5/`.

The build-ready profile targets the ULX3S-85F device with the CABGA381 package.
The hardware flow invokes Yosys, `nextpnr-ecp5`, and Project Trellis `ecppack`
directly; APIO is not required. The default programmer is `ujprog`, and it can
be overridden with `PROGRAMMER` and `PROGRAMMER_FLAGS` on the Make command line.
