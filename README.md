# blueYosys
* **An Advanced, High-Performance Boilerplate Codebase for Lattice ECP5-Based Embedded FPGA Kernel Development using Yosys Opensource Toolchain and Bluespec SystemVerilog (BSV).**

* `blueYosys` is a reusable development environment for designing embedded FPGA kernels in BSV, compiling them into Verilog, building Lattice ECP5 bitstreams with the open-source Yosys toolchain, running Bluesim simulations, and communicating with the FPGA through host-side software.
* It exists to keep kernel logic independent from board-specific infrastructure, eliminate duplicated build scripts, and provide a consistent starting point for new accelerators, processors, peripherals, and future FPGA-board ports.

## Development flow
1. Bluespec Compiler (`bsc`) elaborates the selected BSV project and generates synthesizable Verilog.
2. `blueYosys` combines the generated Verilog with common runtime RTL, ECP5 primitives, board-level wrappers, and pin constraints.
3. APIO drives Yosys and nextpnr-ecp5 to synthesize, place, route, and package the FPGA bitstream.
4. The same project can be validated with Bluesim or programmed onto the target board through the shared Makefile interface.

## File structure
* `boards/`
  * Board-specific top modules, peripherals, constraints, RTL wrappers, and build metadata.
  * `boards/ulx3s/`: build-ready ULX3S-85F support, including the top-level BSV module, SDRAM interface, PLL integration, ECP5 pin constraints, and APIO board selection.
  * `boards/ice40/`: an explicit scaffold for future ICE40 board support. It is intentionally not marked build-ready until a concrete board, constraints, clock/reset logic, and primitive backends are provided.
* `platforms/`
  * FPGA-family and compiler-runtime implementations shared by one or more boards.
  * `platforms/bluespec/`: Verilog runtime modules used by BSC-generated hardware, including FIFO, BRAM, reset, and clock-support logic.
  * `platforms/ecp5/`: ECP5-specific BSV and RTL components such as the `MULT18X18D` backend and simplified floating-point operators.
  * `platforms/ice40/`: extension point for future ICE40-specific primitives and RTL implementations.
* `lib/`
  * Device-independent reusable libraries.
  * `lib/bsv/`: common BSV components such as UART and sub-word BRAM access logic.
  * `lib/cpp/`: host-side and BDPI support code shared by simulations and hardware-facing applications.
* `projects/`
  * Standalone kernel, accelerator, and processor designs.
  * Each project owns its BSV kernel logic, optional processor or data files, host-side C/C++ application, and a small Makefile that imports the common build system.
  * Included projects: `image_proc`, `matrix4x4`, `nn_fc`, `nn_fc_accel`, `nn_fc_zfpe`, `rv32i`, and `test`.
* `mk/`
  * Shared Makefile implementation for synthesis, Bluesim, host compilation, programming, cleanup, and board selection.
  * Project Makefiles normally define only project-specific paths or overrides and then include `mk/project.mk`.
* `scripts/`
  * Repository validation and generated-Verilog post-processing utilities.
  * Includes hierarchy checks, project-content verification, and SDRAM inout-port normalization for BSC-generated Verilog.
* `tools/`
  * Small source-built utilities used by the hardware flow.
  * `replacetoken` is compiled here and used to patch generated Verilog deterministically.
* `docs/`
  * Architecture notes, board-porting guidance, and repository validation metadata.
* `src/`
  * Stable compatibility facade exposing commonly used BSV, RTL, constraint, and C++ paths to existing project code.
* `.github/workflows/`
  * Continuous-integration checks for repository hierarchy, preserved project contents, scripts, Makefiles, and source-built utilities.
* `Makefile`
  * Repository-level dispatcher used to select a project and board from a single command line.

## Prerequisites & Dependencies
* Environment Setup
  * Operating System: Linux is recommended.
  * Hardware Description Language: Bluespec SystemVerilog.
  * Compiler and Simulator: Bluespec Compiler (`bsc`) and Bluesim.
  * FPGA Toolchain: APIO, Yosys, nextpnr-ecp5, and the ECP5 bitstream/programming tools provided by the selected APIO environment.
  * Host Development: GNU Make, GCC/G++, Python 3, and pthread support.
* Supported Hardware
  * Lattice ECP5 on the ULX3S-85F board is the current build-ready target.
  * ICE40 hierarchy and board hooks are reserved for future support but are not yet build-ready.

## How to build
`blueYosys` provides a common Makefile interface across all projects. Select a design with `PROJECT=<name>` and a target board with `BOARD=<name>`.

* List available projects
  * ```make list-projects```
* Validate the repository hierarchy and utilities
  * ```make lint```
* Hardware synthesis and bitstream generation
  * ```make synth PROJECT=test BOARD=ulx3s```
* Bluesim compilation
  * ```make bsim PROJECT=matrix4x4 BOARD=ulx3s```
* Build and run a Bluesim simulation
  * ```make runsim PROJECT=matrix4x4 BOARD=ulx3s```
* Program the FPGA
  * ```make program PROJECT=test BOARD=ulx3s```
* Build a project directly from its directory
  * ```make -C projects/test synth BOARD=ulx3s```

## Cleaning the Workspace
* `make clean PROJECT=<name>`: removes the selected project's synthesis output, Bluesim output, host object directory, and simulation logs.
* `make clean-all`: applies the project cleanup target to every included project and removes generated tool binaries.

## Working examples
* `projects/test`: UART-controlled SDRAM access and basic board-integration validation.
* `projects/image_proc`: streaming image-processing kernel with host-side input/output handling.
* `projects/matrix4x4`: 4x4 floating-point matrix-multiplication accelerator.
* `projects/nn_fc`: fully connected neural-network computation example.
* `projects/nn_fc_accel`: accelerated fully connected neural-network design with additional data-processing logic.
* `projects/nn_fc_zfpe`: fully connected neural-network design integrating ZFP-style compression and decompression blocks.
* `projects/rv32i`: RV32I processor implementation with software images and microbenchmarks.

## Adding a new project
1. Copy the closest example under `projects/`.
2. Keep the project-specific BSV kernel and host software inside the new project directory.
3. Define `ROOTDIR`, `PROJECT_NAME`, and any project-specific overrides in the project's Makefile.
4. Include `$(ROOTDIR)/mk/project.mk` to inherit the common synthesis, simulation, and programming flow.
5. Add the project name to the root `Makefile` project list.

## Notes
* Maintained by Se-Min Lim.
* The current production target is the Lattice ECP5-based ULX3S-85F board.
* Board-independent projects should depend on `lib/` and abstract board interfaces rather than directly importing board-specific implementation details.
