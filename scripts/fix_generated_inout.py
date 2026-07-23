#!/usr/bin/env python3

import argparse
from pathlib import Path


REPLACEMENTS = (
    (".XX_sdram_d_XX(mem_xx_inout16_XX_inout_pins),", "sdram_d,"),
    ("mem_xx_inout16_XX_inout_pins", "sdram_d"),
)


def parseArguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Normalize the generated ULX3S SDRAM inout port."
    )
    parser.add_argument("verilog", type=Path, help="Generated top-level Verilog file")
    return parser.parse_args()


def main() -> int:
    args = parseArguments()
    verilogPath = args.verilog

    if not verilogPath.is_file():
        raise FileNotFoundError(f"Generated Verilog not found: {verilogPath}")

    content = verilogPath.read_text(encoding="utf-8")
    for source, destination in REPLACEMENTS:
        content = content.replace(source, destination)

    temporaryPath = verilogPath.with_suffix(verilogPath.suffix + ".tmp")
    temporaryPath.write_text(content, encoding="utf-8")
    temporaryPath.replace(verilogPath)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
