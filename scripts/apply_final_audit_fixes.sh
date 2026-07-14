#!/usr/bin/env bash
set -euo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly archive="${root_dir}/.blueyosys-final-fixes.tar.gz"
readonly expected_sha256="975c8d194c6694c9797ef2e4515a239d7584ceff77dd1f0f15f9e30712f6911f"

cd "${root_dir}"
cat .blueyosys-fix.part*.b64 | base64 --decode > "${archive}"
printf '%s  %s\n' "${expected_sha256}" "${archive}" | sha256sum --check -
tar -xzf "${archive}"

# Remove the generated host executable retained by the upstream snapshot.
rm -f projects/test/cpp/obj/main
find projects -type d -name obj -empty -delete

# The payload and this one-time installer must not remain in the result.
rm -f .blueyosys-fix.part*.b64 "${archive}"
rm -f "${BASH_SOURCE[0]}"

make lint
