# blueYosys
* **An Advanced, High-Performance Boilerplate Codebase for Lattice ECP5-Based Embedded FPGA Kernel Development using Yosys Opensource Toolchain and Bluespec SystemVerilog (BSV).**
* `blueYosys` separates project logic, reusable libraries, FPGA-family backends, and board integration while providing a consistent simulation-to-bitstream workflow.

## Development flow
1. Bluespec Compiler (`bsc`) elaborates the selected BSV project and generates synthesizable Verilog.
2. Yosys synthesizes the design into an FPGA-family technology netlist.
3. `nextpnr` performs placement and routing for the selected board profile.
4. The FPGA-family packer generates the final bitstream.
5. An optional programmer loads the bitstream onto the board.

## File structure
```text
blueyosys/
├── projects/   self-contained kernels and optional Host applications
├── lib/        device-independent BSV, BSC runtime RTL, and shared C++/BDPI
├── fpga/       FPGA-family BSV and RTL backends for ECP5 and future ICE40 support
├── boards/     concrete board profiles, integration, constraints, and programming
├── scripts/    generated-Verilog post-processing and build-report generation
├── build.mk    shared build, simulation, reporting, and programming flow
└── Makefile    repository-level project dispatcher
```

`fpga/ecp5/` contains the current ECP5 arithmetic backend, `lib/rtl/bsc/` contains the common Bluespec runtime RTL, and `fpga/ice40/` is reserved for the future ICE40 backend.

## Prerequisites & Dependencies
* **Platform and hardware:** Linux is recommended. `BOARD=ulx3s-85f` is currently build-ready for the Lattice ECP5-based ULX3S-85F.
* **HDL and FPGA tools:** Install Bluespec Compiler (`bsc`) and Bluesim separately. OSS CAD Suite provides Yosys, `nextpnr-ecp5`, Project Trellis `ecppack`, and common programming tools such as `openFPGALoader`. `ujprog` is the default programmer and can be replaced through `PROGRAMMER` and `PROGRAMMER_FLAGS`.
* **Host tools:** GNU Make, GCC/G++, Python 3, and pthread support.

### Installation on Ubuntu x86-64 (OSS CAD Suite)
The following commands install the latest OSS CAD Suite release under `~/.local/opt`, enable it for Bash, and verify the tools. Bluespec Compiler is still required separately.

```bash
sudo apt update
sudo apt install -y build-essential curl python3

mkdir -p "$HOME/.local/opt"
OSS_CAD_URL="$(
  curl -fsSL https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest |
  python3 -c 'import json, sys; r = json.load(sys.stdin); print(next(a["browser_download_url"] for a in r["assets"] if a["name"].startswith("oss-cad-suite-linux-x64-") and a["name"].endswith(".tgz")))'
)"
curl -fL "$OSS_CAD_URL" -o /tmp/oss-cad-suite.tgz
rm -rf "$HOME/.local/opt/oss-cad-suite"
tar -xzf /tmp/oss-cad-suite.tgz -C "$HOME/.local/opt"

grep -qxF 'source "$HOME/.local/opt/oss-cad-suite/environment"' "$HOME/.bashrc" || \
  echo 'source "$HOME/.local/opt/oss-cad-suite/environment"' >> "$HOME/.bashrc"
source "$HOME/.local/opt/oss-cad-suite/environment"

command -v yosys nextpnr-ecp5 ecppack openFPGALoader
```

For Ubuntu ARM64, replace `linux-x64` with `linux-arm64` in the asset-name filter. To program ULX3S with the bundled programmer, use:

```bash
make program PROJECT=basic BOARD=ulx3s-85f \
  PROGRAMMER=openFPGALoader PROGRAMMER_FLAGS="-b ulx3s"
```

## How to build
Select a design with `PROJECT=<name>` and a concrete target with `BOARD=<profile>`.

* Generate Verilog from BSV: `make verilog PROJECT=basic BOARD=ulx3s-85f`
* Generate the Yosys netlist: `make netlist PROJECT=basic BOARD=ulx3s-85f`
* Run place-and-route: `make pnr PROJECT=basic BOARD=ulx3s-85f`
* Generate the bitstream: `make bitstream PROJECT=basic BOARD=ulx3s-85f`
* Run the complete hardware flow: `make synth PROJECT=basic BOARD=ulx3s-85f`
* Build the Host application: `make host PROJECT=basic`
* Compile Bluesim: `make bsim PROJECT=basic BOARD=ulx3s-85f`
* Build and run Bluesim: `make runsim PROJECT=basic BOARD=ulx3s-85f`
* Program the FPGA: `make program PROJECT=basic BOARD=ulx3s-85f`
* Build directly from a project: `make -C projects/basic synth BOARD=ulx3s-85f`

The bitstream and reports are written under `projects/<project>/build/`.

## Build reports
Every hardware build leaves inspectable synthesis, utilization, and timing artifacts:

```text
mkTop.yosys.rpt       human-readable post-synthesis cell statistics
mkTop.yosys.json      machine-readable Yosys statistics
mkTop.nextpnr.json    post-pack utilization and routed Fmax data
mkTop.nextpnr.log     complete place-and-route log
mkTop.utilization.rpt combined resource and timing summary
```

When nextpnr reports a timing failure, the build still returns a failure status, but `blueYosys` attempts to generate `mkTop.utilization.rpt` from the nextpnr report or saved log.

## Build stages
```text
verilog -> netlist -> pnr -> bitstream -> synth
   bsc       yosys    nextpnr     packer
```

The stages can be called independently to inspect intermediate Verilog, netlists, placement, routing, and reports.

## Cleaning the workspace
* `make clean PROJECT=<name>` removes the selected project's generated hardware, Bluesim, Host, log, and report files.
* `make clean-all` cleans every included project.

## Working examples
* `projects/basic`: UART streaming, SDRAM read-back, and SimpleFloat MAC example.
* `projects/matmul`: 4x4 floating-point matrix-multiplication accelerator.
* `projects/nn_fc`: Fully connected neural-network computation example.
* `projects/nn_fc_accel`: Accelerated fully connected neural-network design with additional data-processing logic.
* `projects/nn_fc_zfpe`: Fully connected neural-network design integrating ZFP-style compression and decompression blocks.

## Adding a new project
1. Copy the closest example under `projects/`.
2. Keep project-specific BSV and Host software inside the project directory.
3. Define `ROOTDIR` and `PROJECT_NAME` in the project Makefile.
4. Include `$(ROOTDIR)/build.mk`.
5. Add the project name to the root `Makefile` project list.

## Notes
* Maintained by Se-Min Lim.
* The current production target is the Lattice ECP5-based ULX3S-85F.
* Board-independent projects should depend on `lib/` and abstract board interfaces rather than FPGA- or board-specific implementations.
