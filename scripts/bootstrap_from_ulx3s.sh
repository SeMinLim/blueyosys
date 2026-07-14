#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly payload_b64="${script_dir}/.bootstrap_payload.b64"
readonly payload_script="${script_dir}/.bootstrap_payload.sh"
readonly expected_payload_sha256="4fdad25dcdf2c041307703137bd2e9d0ea5d83bf990cbe9110c4d1144339a30a"

cleanup() {
    rm -f "${payload_b64}" "${payload_script}"
}
trap cleanup EXIT

# Correct the two transport-only substitutions detected by Git blob SHA checks.
grep -q 'Qk9SRF9CU0lN' "${script_dir}/bootstrap.part02.b64"
grep -q '7ZWj7ISx' "${script_dir}/bootstrap.part05.b64"
sed -i 's/Qk9SRF9CU0lN/Qk9BUkRfQlNJ/' "${script_dir}/bootstrap.part02.b64"
sed -i 's/7ZWj7ISx/7ZWp7ISx/' "${script_dir}/bootstrap.part05.b64"

cat "${script_dir}"/bootstrap.part*.b64 > "${payload_b64}"
printf '%s  %s\n' "${expected_payload_sha256}" "${payload_b64}" | sha256sum --check -
base64 --decode "${payload_b64}" > "${payload_script}"
chmod +x "${payload_script}"

bash "${payload_script}"

# Keep the readable, fully decoded migration script in the resulting repository.
cp "${payload_script}" "${script_dir}/bootstrap_from_ulx3s.sh"
chmod +x "${script_dir}/bootstrap_from_ulx3s.sh"
rm -f "${script_dir}"/bootstrap.part*.b64 "${payload_b64}"
trap - EXIT
rm -f "${payload_script}"
