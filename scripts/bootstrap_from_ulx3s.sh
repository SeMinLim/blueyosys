#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly transport_b64="${script_dir}/.bootstrap_transport.b64"
readonly verified_b64="${script_dir}/.bootstrap_verified.b64"
readonly payload_script="${script_dir}/.bootstrap_payload.sh"
readonly expected_payload_sha256="4fdad25dcdf2c041307703137bd2e9d0ea5d83bf990cbe9110c4d1144339a30a"

cleanup() {
    rm -f "${transport_b64}" "${verified_b64}" "${payload_script}"
}
trap cleanup EXIT

cat "${script_dir}"/bootstrap.part*.b64 > "${transport_b64}"
base64 --decode "${transport_b64}" > "${payload_script}"

python3 - "${payload_script}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()

expected_line = b"BSIM_TOP_SOURCE ?= $(BOARD_BSIM_TOP_SOURCE)"
lines = data.splitlines(keepends=True)
line_matches = 0
for index, line in enumerate(lines):
    if line.startswith(b"BSIM_TOP_SOURCE ?="):
        ending = b"\n" if line.endswith(b"\n") else b""
        print(f"repairing build-variable line: {line.rstrip()!r}", flush=True)
        lines[index] = expected_line + ending
        line_matches += 1
if line_matches != 1:
    raise SystemExit(f"unexpected BSIM_TOP_SOURCE line count: {line_matches}")
data = b"".join(lines)

old_korean = "핣성".encode("utf-8")
new_korean = "합성".encode("utf-8")
korean_matches = data.count(old_korean)
print(f"repairing Korean transport substitution: {korean_matches} occurrence(s)", flush=True)
if korean_matches != 1:
    raise SystemExit(f"unexpected Korean repair count: {korean_matches}")
data = data.replace(old_korean, new_korean, 1)
path.write_bytes(data)
PY

base64 --wrap=0 "${payload_script}" > "${verified_b64}"
actual_payload_sha256="$(sha256sum "${verified_b64}" | awk '{print $1}')"
printf 'verified bootstrap payload SHA-256: %s\n' "${actual_payload_sha256}"
if [[ "${actual_payload_sha256}" != "${expected_payload_sha256}" ]]; then
    echo "bootstrap payload checksum mismatch" >&2
    exit 1
fi

chmod +x "${payload_script}"
bash -n "${payload_script}"
bash "${payload_script}"

# Keep the readable, fully decoded migration script in the resulting repository.
cp "${payload_script}" "${script_dir}/bootstrap_from_ulx3s.sh"
chmod +x "${script_dir}/bootstrap_from_ulx3s.sh"
rm -f "${script_dir}"/bootstrap.part*.b64 "${transport_b64}" "${verified_b64}"
trap - EXIT
rm -f "${payload_script}"
