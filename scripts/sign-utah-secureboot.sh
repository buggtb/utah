#!/usr/bin/env bash
# Sign Utah's custom kernels and out-of-tree modules for Secure Boot.
#
# This mirrors ublue-os/akmods' MOK model: one long-lived Utah Machine Owner
# Key signs everything Fedora's own key does not (the source-built OGC kernel
# and the NVIDIA open modules). The public certificate ships in the image and
# the user enrolls it once with utah-enroll-secure-boot-key; the private key
# lives only in the kernel-cache builder and never in a shipped layer.
#
# Usage:
#   sign-utah-secureboot.sh kernel <release>
#     sbsign the OGC vmlinuz for <release> and verify it with sbverify.
#   sign-utah-secureboot.sh modules <release> <moduledir>
#     sign every .ko under <moduledir> with the kernel's sign-file and the
#     Utah MOK, so lockdown accepts them once the MOK is enrolled.
#
# Key material comes from ${UTAH_SECUREBOOT_KEYDIR:-packages/secureboot}:
# utah-mok.priv (private) and utah-mok.der (public). When the private key is
# absent -- a plain local build outside the kernel-cache image -- signing is
# skipped with a warning and the kernel stays unsigned, exactly like akmods'
# test-key fallback. An unsigned custom kernel cannot boot under Secure Boot.
set -euo pipefail

KEYDIR="${UTAH_SECUREBOOT_KEYDIR:-packages/secureboot}"
PRIV="${KEYDIR}/utah-mok.priv"
DER="${KEYDIR}/utah-mok.der"

mode="${1:?usage: sign-utah-secureboot.sh kernel <release> | modules <release> <moduledir>}"
release="${2:?kernel release is required}"

if [[ ! -s "${PRIV}" ]]; then
  echo "WARNING: ${PRIV} not present; leaving ${release} unsigned (Secure Boot will reject it)" >&2
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
openssl x509 -inform DER -in "${DER}" -out "${work}/utah-mok.crt"

case "${mode}" in
  kernel)
    # install-ogc-kernel.sh lays the image down at /boot/vmlinuz-<release>
    # (a source build has no kernel-core package to place the Fedora-layout
    # /usr/lib/modules/<release>/vmlinuz copy); accept either layout.
    vmlinuz="/boot/vmlinuz-${release}"
    [[ -f "${vmlinuz}" ]] || vmlinuz="/usr/lib/modules/${release}/vmlinuz"
    [[ -f "${vmlinuz}" ]] || { echo "no vmlinuz for ${release}" >&2; exit 1; }
    sbsign --cert "${work}/utah-mok.crt" --key "${PRIV}" \
      "${vmlinuz}" --output "${vmlinuz}.signed"
    mv "${vmlinuz}.signed" "${vmlinuz}"
    sbverify --list "${vmlinuz}"
    sbverify --cert "${work}/utah-mok.crt" "${vmlinuz}"
    echo "Signed ${vmlinuz} with the Utah MOK"
    ;;
  modules)
    moduledir="${3:?module directory is required}"
    sign_file="/usr/lib/modules/${release}/build/scripts/sign-file"
    [[ -x "${sign_file}" ]] || { echo "no sign-file for ${release}" >&2; exit 1; }
    count=0
    while IFS= read -r ko; do
      "${sign_file}" sha512 "${PRIV}" "${work}/utah-mok.crt" "${ko}"
      count=$((count + 1))
    done < <(find "${moduledir}" -name '*.ko' -type f)
    echo "Signed ${count} modules for ${release} with the Utah MOK"
    ;;
  *)
    echo "unknown mode ${mode}" >&2
    exit 1
    ;;
esac
