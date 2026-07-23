#!/usr/bin/env python3
"""Generate a concise blueYosys synthesis and implementation report."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


UTIL_RE = re.compile(
    r"^\s*(?:Info:\s*)?([A-Za-z0-9_.$-]+):\s*(\d+)\s*/\s*(\d+)"
)
FMAX_RE = re.compile(
    r"Max frequency for clock\s+'([^']+)':\s*"
    r"([0-9]+(?:\.[0-9]+)?)\s+MHz\s+"
    r"\((PASS|FAIL)\s+at\s+([0-9]+(?:\.[0-9]+)?)\s+MHz\)"
)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError(f"report input does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"expected a JSON object in {path}")
    return data


def integer(value: Any) -> int:
    if isinstance(value, dict):
        value = value.get("count", value.get("used", 0))
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        return int(float(value))
    return 0


def number(value: Any) -> float:
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        return float(value)
    return 0.0


def yosys_stats(document: dict[str, Any], top: str) -> tuple[int, dict[str, int]]:
    stats: dict[str, Any] | None = None

    # With ``stat -json -top``, recent Yosys releases put the aggregate design
    # statistics at the JSON top level.  Older releases and calls without
    # ``-top`` expose only the per-module entries.  Accept both layouts.
    aggregate = document.get("design")
    if isinstance(aggregate, dict):
        stats = aggregate

    modules = document.get("modules", {})
    if stats is None and isinstance(modules, dict):
        for name in (top, f"\\{top}"):
            candidate = modules.get(name)
            if isinstance(candidate, dict):
                stats = candidate
                break
        if stats is None and modules:
            only = next(iter(modules.values()))
            if isinstance(only, dict):
                stats = only

    if stats is None:
        return 0, {}

    total = integer(stats.get("num_cells", 0))
    raw_types = stats.get("num_cells_by_type", {})
    cell_types: dict[str, int] = {}
    if isinstance(raw_types, dict):
        for name, count in raw_types.items():
            parsed = integer(count)
            if parsed:
                cell_types[str(name)] = parsed
    return total, cell_types


def nextpnr_json_stats(
    document: dict[str, Any],
) -> tuple[dict[str, tuple[int, int]], dict[str, tuple[float, float]]]:
    resources: dict[str, tuple[int, int]] = {}
    raw_util = document.get("utilization", {})
    if isinstance(raw_util, dict):
        for name, values in raw_util.items():
            if not isinstance(values, dict):
                continue
            resources[str(name)] = (
                integer(values.get("used", 0)),
                integer(values.get("available", 0)),
            )

    clocks: dict[str, tuple[float, float]] = {}
    raw_fmax = document.get("fmax", {})
    if isinstance(raw_fmax, dict):
        for name, values in raw_fmax.items():
            if not isinstance(values, dict):
                continue
            clocks[str(name)] = (
                number(values.get("achieved", 0.0)),
                number(values.get("constraint", 0.0)),
            )
    return resources, clocks


def nextpnr_log_stats(
    path: Path,
) -> tuple[dict[str, tuple[int, int]], dict[str, tuple[float, float]]]:
    resources: dict[str, tuple[int, int]] = {}
    clocks: dict[str, tuple[float, float]] = {}
    if not path.is_file():
        return resources, clocks

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        util_match = UTIL_RE.match(line)
        if util_match:
            name, used, available = util_match.groups()
            resources[name] = (int(used), int(available))

        fmax_match = FMAX_RE.search(line)
        if fmax_match:
            name, achieved, _status, constraint = fmax_match.groups()
            clocks[name] = (float(achieved), float(constraint))
    return resources, clocks


def percentage(used: int, available: int) -> str:
    if available <= 0:
        return "n/a"
    return f"{100.0 * used / available:.2f}%"


def render_report(
    *,
    project: str,
    board: str,
    top: str,
    yosys_total: int,
    yosys_cells: dict[str, int],
    resources: dict[str, tuple[int, int]],
    clocks: dict[str, tuple[float, float]],
    yosys_path: Path,
    nextpnr_path: Path | None,
) -> str:
    lines = [
        "blueYosys Resource Utilization Report",
        "======================================",
        f"Project:    {project}",
        f"Board:      {board}",
        f"Top module: {top}",
        "",
        "Yosys post-synthesis cell statistics",
        "------------------------------------",
        f"Total cells: {yosys_total}",
    ]

    if yosys_cells:
        lines.extend(
            [
                "",
                f"{'Cell type':<34} {'Count':>10}",
                f"{'-' * 34} {'-' * 10}",
            ]
        )
        for name, count in sorted(
            yosys_cells.items(), key=lambda item: (-item[1], item[0])
        ):
            lines.append(f"{name:<34} {count:>10}")
    else:
        lines.append("No Yosys cell statistics were found.")

    lines.extend(
        [
            "",
            "nextpnr post-pack device utilization",
            "------------------------------------",
            "Only resources with non-zero use are listed.",
        ]
    )
    nonzero_resources = {
        name: values for name, values in resources.items() if values[0] > 0
    }
    if nonzero_resources:
        lines.extend(
            [
                "",
                f"{'Resource':<28} {'Used':>10} {'Available':>12} {'Usage':>10}",
                f"{'-' * 28} {'-' * 10} {'-' * 12} {'-' * 10}",
            ]
        )
        for name, (used, available) in sorted(nonzero_resources.items()):
            lines.append(
                f"{name:<28} {used:>10} {available:>12} "
                f"{percentage(used, available):>10}"
            )
    else:
        lines.append("No nextpnr utilization data were found.")

    lines.extend(["", "Clock timing", "------------"])
    if clocks:
        lines.extend(
            [
                "",
                f"{'Clock':<58} {'Achieved':>12} {'Target':>12} "
                f"{'Margin':>12} {'Status':>8}",
                f"{'-' * 58} {'-' * 12} {'-' * 12} {'-' * 12} {'-' * 8}",
            ]
        )
        for name, (achieved, constraint) in sorted(clocks.items()):
            margin = achieved - constraint
            status = "PASS" if achieved > constraint else "FAIL"
            lines.append(
                f"{name:<58} {achieved:>9.2f} MHz {constraint:>9.2f} MHz "
                f"{margin:>+9.2f} MHz {status:>8}"
            )
    else:
        lines.append("No nextpnr clock data were found.")

    lines.extend(
        [
            "",
            "Machine-readable source reports",
            "-------------------------------",
            f"Yosys:   {yosys_path}",
            f"nextpnr: {nextpnr_path if nextpnr_path is not None else 'not available'}",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--board", required=True)
    parser.add_argument("--top", required=True)
    parser.add_argument("--yosys-json", type=Path, required=True)
    parser.add_argument("--nextpnr-json", type=Path)
    parser.add_argument("--nextpnr-log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        yosys_document = load_json(args.yosys_json)
        yosys_total, yosys_cells = yosys_stats(yosys_document, args.top)

        resources: dict[str, tuple[int, int]] = {}
        clocks: dict[str, tuple[float, float]] = {}
        nextpnr_source: Path | None = None

        if args.nextpnr_json is not None and args.nextpnr_json.is_file():
            try:
                nextpnr_document = load_json(args.nextpnr_json)
            except RuntimeError as exc:
                print(f"warning: {exc}; falling back to the nextpnr log", file=sys.stderr)
            else:
                resources, clocks = nextpnr_json_stats(nextpnr_document)
                nextpnr_source = args.nextpnr_json

        if (not resources or not clocks) and args.nextpnr_log is not None:
            log_resources, log_clocks = nextpnr_log_stats(args.nextpnr_log)
            if not resources:
                resources = log_resources
            if not clocks:
                clocks = log_clocks
            if nextpnr_source is None and args.nextpnr_log.is_file():
                nextpnr_source = args.nextpnr_log

        report = render_report(
            project=args.project,
            board=args.board,
            top=args.top,
            yosys_total=yosys_total,
            yosys_cells=yosys_cells,
            resources=resources,
            clocks=clocks,
            yosys_path=args.yosys_json,
            nextpnr_path=nextpnr_source,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
