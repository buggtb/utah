#!/usr/bin/env bash
# Enroll Utah's Secure Boot key (Machine Owner Key) on this machine.
#
# Mirrors ublue-os/bluefin's `ujust enroll-secure-boot-key`: Utah's custom OGC
# kernel and NVIDIA modules are signed with the Utah MOK, which firmware does
# not trust until it is enrolled. This queues the enrollment; on the next boot
# the blue MokManager screen completes it. This is a physical-presence step by
# design: have the enrollment password ready at the console.
#
# Enter the password "utahraptor" when MokManager asks for it.
set -euo pipefail

CERT="${UTAH_SECUREBOOT_CERT:-/etc/pki/utah/certs/utah-mok.der}"
[[ -f "${CERT}" ]] || { echo "Utah MOK certificate not found at ${CERT}" >&2; exit 1; }

if mokutil --test-key "${CERT}" >/dev/null 2>&1; then
  echo "Utah MOK is already enrolled; nothing to do."
  exit 0
fi

echo 'Enter the password "utahraptor" when MokManager prompts after reboot.'
sudo mokutil --timeout -1
sudo mokutil --import "${CERT}"
echo "Reboot, choose Enroll MOK in MokManager, and enter the password."
