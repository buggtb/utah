#!/usr/bin/env bash
# Build a single-architecture UEFI live ISO from a Utah bootc image.
# Usage: build-iso.sh IMAGE OUTPUT_ISO [TITLE] [DEBUG] [PUBLISHED_IMAGE]
set -euo pipefail

IMAGE="${1:?image ref is required}"
OUTPUT_ISO="${2:?output ISO path is required}"
TITLE="${3:-Utah Live}"
DEBUG="${4:-0}"
# SOURCE_IMAGE may be localhost for development, but the embedded store and
# installer recipe use this stable, publishable reference.
PUBLISHED_IMAGE="${5:-ghcr.io/projectbluefin/utah:testing}"
# Live-ISO size budget (#128). The ISO embeds the full container store for
# offline install, so image growth shows up doubled on the ISO. The last fully
# passing run (2026-09-06) was 7.7G; the 2026-09-18 run was 8.6G once the
# ~4 GB package repository stopped being removed from the image. The ceiling
# sits between those two: 8 GB is above the last passing run so a clean build
# passes, but below the grown size, so the exact #128 regression fails the job
# instead of landing silently. Raise N only after the real fix -- unmount,
# never COPY, the package repository (#128) -- lands; #105 adds linux-firmware
# and ~30 parity packages on top, so expect to revisit N.
# Prototype A raises the ceiling to 10G as a dedup baseline: with
# composefs/erofs and reflink/hardlink dedup the ISO should land well below
# the non-deduped 10G wall. Keep 8G as the default; set UTAH_ISO_MAX_GB=10 for
# prototype A baseline comparisons.
# Override per-run with UTAH_ISO_MAX_GB (GB) without editing this script.
ISO_MAX_GB="${UTAH_ISO_MAX_GB:-8}"
# Prototype A dry-run: when disk is low, skip the 30G fallocate-backed QEMU
# path and estimate sizes via tunaos-build-sim semantics.
PROTOTYPE_A_DRYRUN="${UTAH_ISO_DRYRUN:-0}"
LABEL="UTAH_LIVE"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$(dirname "${OUTPUT_ISO}")"
OUTPUT_ISO="$(realpath "${OUTPUT_ISO}")"
LIVE_IMAGE="localhost/utah-live:testing"
# Not TMPDIR, and not /tmp. Assembly stages an uncompressed squashfs root of
# well over 13G, and /tmp is a tmpfs sized to a fraction of RAM -- the build
# gets most of the way through and then dies in a heap of "No space left on
# device" from cp, which reads as a broken image rather than a full staging
# area. Stage on real disk; UTAH_ISO_WORKDIR to put it somewhere else.
WORK="$(mktemp -d "${UTAH_ISO_WORKDIR:-/var/tmp}/utah-iso.XXXXXX")"
# The assembly step below runs under `podman unshare` and writes a squashfs
# root whose files belong to subordinate uids. Outside that namespace they are
# unremovable, so a plain rm here fails with Permission denied on every one of
# them -- leaving a ~13G tree behind and, because the trap is the last thing to
# run, failing the whole recipe after the ISO was written successfully.
cleanup_work() { podman unshare rm -rf "${WORK}" 2>/dev/null || rm -rf "${WORK}" 2>/dev/null || true; }
trap cleanup_work EXIT

cd "${ROOT}"
echo "Building live environment from ${IMAGE}"
# flatpak installs through bwrap, which needs to create a user namespace inside
# the build container; rootless podman refuses that without sys_admin, and the
# failure surfaces as an unrelated-looking "No remote refs found for flathub".
# projectbluefin/iso passes the same two flags to build the same layer.
podman build --layers \
    --cap-add sys_admin --security-opt label=disable \
    --build-arg SOURCE_IMAGE="${IMAGE}" \
    --build-arg TARGET_IMAGE="${PUBLISHED_IMAGE}" \
    --build-arg DEBUG="${DEBUG}" \
    --tag "${LIVE_IMAGE}" \
    --file iso/live/Containerfile iso/live

# Image mounts live in rootless Podman's user namespace. Keep the complete
# mount/copy/assembly operation inside podman unshare rather than leaking a
# namespace-private mount path back to the host shell.
podman unshare bash -s -- "${LIVE_IMAGE}" "${IMAGE}" "${PUBLISHED_IMAGE}" "${OUTPUT_ISO}" "${TITLE}" "${LABEL}" "${WORK}" "${ISO_MAX_GB}" <<'ASSEMBLY'
set -euo pipefail
LIVE_IMAGE="$1"
PAYLOAD_IMAGE="$2"
PUBLISHED_IMAGE="$3"
OUTPUT_ISO="$4"
TITLE="$5"
LABEL="$6"
WORK="$7"
ISO_MAX_GB="$8"
MOUNT="$(podman image mount "${LIVE_IMAGE}")"
cleanup() {
    set +e
    podman image unmount "${LIVE_IMAGE}" >/dev/null 2>&1
}
trap cleanup EXIT

KERNEL="$(find "${MOUNT}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)"
[[ -n "${KERNEL}" ]] || { echo 'No kernel found in live image' >&2; exit 1; }
VMLINUZ="$(python3 iso/scripts/live-kernel.py "${MOUNT}" "${KERNEL}")"
INITRD="${MOUNT}/usr/lib/modules/${KERNEL}/initramfs.img"
# Prototype C: Secure Boot via shim+GRUB (Fedora signed). Shim is the
# removable-media fallback (BOOTX64.EFI); GRUB is the second stage.
SHIM="$(find "${MOUNT}/usr/lib/efi/shim" -name 'shimx64.efi' -type f 2>/dev/null | head -1)"
if [[ -z "${SHIM}" ]]; then
    SHIM="$(find "${MOUNT}/boot/efi" -name 'shimx64.efi' -type f 2>/dev/null | head -1)"
fi
GRUB="$(find "${MOUNT}/usr/lib/efi/grub2" -name 'grubx64.efi' -type f 2>/dev/null | head -1)"
for file in "${VMLINUZ}" "${INITRD}" "${SHIM}" "${GRUB}"; do
    [[ -f "${file}" ]] || { echo "Missing live boot file: ${file}" >&2; exit 1; }
done
# Verify shim/grub carry a Secure Boot signature when tooling is available.
if command -v sbverify >/dev/null 2>&1; then
    sbverify --list "${SHIM}" 2>&1 | head -20 || echo "sbverify shim check failed" >&2
    sbverify --list "${GRUB}" 2>&1 | head -20 || echo "sbverify grub check failed" >&2
elif command -v pesign >/dev/null 2>&1; then
    pesign -S -i "${SHIM}" 2>&1 | head -20 || echo "pesign shim check failed" >&2
fi

# Start with the live image filesystem, then add the target OCI image as a VFS
# containers-storage graphroot. This is Dakota's offline-payload design adapted
# for Utah's conventional bootc (non-composefs) install path.
SQUASHFS_ROOT="${WORK}/squashfs-root"
mkdir -p "${SQUASHFS_ROOT}"
cp -a "${MOUNT}/." "${SQUASHFS_ROOT}/"

HOST_STORE="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "")"
if [[ -z "${HOST_STORE}" || ! -d "${HOST_STORE}" ]]; then
    HOST_STORE="${HOME:-/var/home/james}/.local/share/containers/storage"
fi
if [[ ! -d "${HOST_STORE}" ]]; then
    HOST_STORE="/var/home/james/.local/share/containers/storage"
fi
echo "Prototype B: hardlinking host storage ${HOST_STORE} into squashfs (no dir: copy)"
echo "Installer will use containers-storage:localhost/utah:testing from the live root"
mkdir -p "${SQUASHFS_ROOT}/usr/lib/containers/storage"
if cp -al "${HOST_STORE}/." "${SQUASHFS_ROOT}/usr/lib/containers/storage/" 2>/dev/null; then
    echo "Hardlinked host storage into squashfs root (zero duplicate bytes on same filesystem)"
else
    echo "Hardlink failed (cross-device), falling back to cp -a (still no dir: copy)"
    cp -a "${HOST_STORE}/." "${SQUASHFS_ROOT}/usr/lib/containers/storage/"
fi
# Point the embedded installer recipe at the local store. The live image was
# built with TARGET_IMAGE=${PUBLISHED_IMAGE} (ghcr.io...), but prototype B
# intentionally uses localhost so fisherman resolves the hardlinked store
# without pulling. Patch both recipe and images.json inside the squashfs root.
PROTO_RECIPE_REF="localhost/utah:testing"
if [[ -f "${SQUASHFS_ROOT}/etc/bootc-installer/recipe.json" ]]; then
    python3 - "${SQUASHFS_ROOT}/etc/bootc-installer/recipe.json" "${PROTO_RECIPE_REF}" <<'PY'
import json, sys
path, ref = sys.argv[1], sys.argv[2]
p = __import__('pathlib').Path(path)
data = json.loads(p.read_text())
data["imgref"] = ref
data["targetImgref"] = ref
data["image"] = ""
data["local_imgref"] = f"containers-storage:{ref}"
# keep other keys (bootloader, composeFsBackend, filesystem, etc.) as-is
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"Patched {path} -> local_imgref containers-storage:{ref}")
PY
fi
if [[ -f "${SQUASHFS_ROOT}/etc/bootc-installer/images.json" ]]; then
    python3 - "${SQUASHFS_ROOT}/etc/bootc-installer/images.json" "${PROTO_RECIPE_REF}" <<'PY'
import json, sys
path, ref = sys.argv[1], sys.argv[2]
p = __import__('pathlib').Path(path)
data = json.loads(p.read_text())
data["default_image"] = ref
if "images" in data and data["images"]:
    data["images"][0]["imgref"] = ref
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"Patched {path} -> default_image {ref}")
PY
fi
# Verify the store actually contains the localhost ref (image JSON exists)
if [[ -d "${SQUASHFS_ROOT}/usr/lib/containers/storage/overlay-images" || -d "${SQUASHFS_ROOT}/usr/lib/containers/storage/images" ]]; then
    echo "Storage image directory present in squashfs root"
    ls "${SQUASHFS_ROOT}/usr/lib/containers/storage/" | head -n 20
else
    echo "WARNING: storage imagestore not found under squashfs root" >&2
    ls -R "${SQUASHFS_ROOT}/usr/lib/containers/storage" 2>&1 | head -n 40 || true
fi

fi
# Prototype A composefs: if mkcomposefs is available in the live image,
# generate a composefs image with digest store for content-addressed dedup.
# The digest store lives alongside the payload and shares identical file
# content via hardlinks, so the live root + payload share storage without
# duplication. This is the tunaos-build-sim semantics: composefs/erofs
# dedup is estimated by measuring shared extents.
if podman run --rm --privileged \
    -v "${SQUASHFS_ROOT}:/target" \
    "${LIVE_IMAGE}" sh -c 'command -v mkcomposefs >/dev/null 2>&1' 2>/dev/null; then
    echo "Prototype A: mkcomposefs available in live image, generating composefs digest store"
    mkdir -p "${SQUASHFS_ROOT}/usr/lib/composefs/store"
    # Generate composefs from the squashfs-root using the live image's mkcomposefs
    # so the payload and live root share the digest store.
    podman run --rm --privileged \
        -v "${SQUASHFS_ROOT}:/target" \
        "${LIVE_IMAGE}" sh -c 'mkcomposefs --digest-store=/target/usr/lib/composefs/store /target /target/usr/lib/composefs/composefs.img 2>&1 | head -n 20; echo "mkcomposefs exit: $?"' || true
    # Hardlink any duplicate files in the payload store into the composefs store
    # for dedup accounting (tunaos-build-sim style estimation)
    if command -v hardlink >/dev/null 2>&1; then
        hardlink -c "${SQUASHFS_ROOT}/usr/lib/composefs/store" "${SQUASHFS_ROOT}/usr/lib/containers/storage" 2>&1 | tail -n 5 || true
    fi
fi
rm -rf "${PAYLOAD_EXPORT}" "${PAYLOAD_STORE}" "${STORAGE_CONF}"

SQUASHFS="${WORK}/squashfs.img"
EROFS="${WORK}/erofs.img"
echo "Creating live rootfs (${KERNEL})"
# Prototype A: measure both mksquashfs and mkfs.erofs sizes for comparison.
# mksquashfs is the baseline; mkfs.erofs with zstd gives the EROFS dedup path.
# tunaos-build-sim dry-run estimates the dedup saving without requiring a full
# 30G fallocate when disk is low (UTAH_ISO_DRYRUN=1 or <20G free).
echo "Prototype A: building squashfs (baseline) and erofs (dedup) for size comparison"
mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" \
    -noappend -comp zstd -Xcompression-level 3 -b 131072 -processors 4 \
    -wildcards -e 'proc/*' -e 'sys/*' -e 'dev/*' -e run -e tmp
squashfs_size=$(du -b "${SQUASHFS}" | cut -f1)
squashfs_human=$(du -sh "${SQUASHFS}" | cut -f1)
echo "Prototype A mksquashfs size: ${squashfs_human} (${squashfs_size} bytes)"
# EROFS via mkfs.erofs if available on host or in live image
if command -v mkfs.erofs >/dev/null 2>&1; then
    echo "Prototype A: building EROFS image via mkfs.erofs -z zstd,level=3"
    mkfs.erofs -z zstd,level=3 "${EROFS}" "${SQUASHFS_ROOT}" 2>&1 | tail -n 20 || true
    if [[ -f "${EROFS}" ]]; then
        erofs_size=$(du -b "${EROFS}" | cut -f1 || echo 0)
        erofs_human=$(du -sh "${EROFS}" | cut -f1 || echo "0")
        echo "Prototype A mkfs.erofs size: ${erofs_human} (${erofs_size} bytes)"
        # Use the smaller of the two for the ISO (take erofs if it wins)
        if [[ "${erofs_size}" -gt 0 && "${erofs_size}" -lt "${squashfs_size}" ]]; then
            echo "Prototype A: EROFS is smaller, using EROFS image as squashfs.img for ISO"
            mv "${EROFS}" "${SQUASHFS}"
        else
            rm -f "${EROFS}" || true
            echo "Prototype A: squashfs remains smaller or erofs unavailable"
        fi
    fi
elif podman run --rm "${LIVE_IMAGE}" sh -c 'command -v mkfs.erofs >/dev/null 2>&1' 2>/dev/null; then
    echo "Prototype A: mkfs.erofs in live image, building EROFS via container"
    podman run --rm --privileged -v "${SQUASHFS_ROOT}:/src:ro" -v "${WORK}:/out" "${LIVE_IMAGE}" sh -c 'mkfs.erofs -z zstd,level=3 /out/erofs.img /src 2>&1 | tail -n 20; echo "mkfs.erofs exit: $?"' || true
    if [[ -f "${EROFS}" ]]; then
        erofs_size=$(du -b "${EROFS}" | cut -f1 || echo 0)
        erofs_human=$(du -sh "${EROFS}" | cut -f1 || echo "0")
        echo "Prototype A mkfs.erofs (container) size: ${erofs_human} (${erofs_size} bytes)"
        squashfs_size_after=$(du -b "${SQUASHFS}" | cut -f1)
        if [[ "${erofs_size}" -gt 0 && "${erofs_size}" -lt "${squashfs_size_after}" ]]; then
            mv "${EROFS}" "${SQUASHFS}"
        else
            rm -f "${EROFS}" || true
        fi
    fi
else
    echo "Prototype A: mkfs.erofs not found on host nor in live image, using squashfs only"
fi
final_rootfs_size=$(du -b "${SQUASHFS}" | cut -f1)
final_rootfs_human=$(du -sh "${SQUASHFS}" | cut -f1)
echo "Prototype A final rootfs size: ${final_rootfs_human} (${final_rootfs_size} bytes)"
# tunaos-build-sim dry-run estimation when disk low: report estimated ISO size
avail_kb=$(df --output=avail "${WORK}" | tail -1 | tr -d ' ')
avail_gb=$(( avail_kb / 1024 / 1024 ))
iso_estimate_bytes=$(( final_rootfs_size + 200 * 1024 * 1024 ))
iso_estimate_human=$(numfmt --to=iec-i --suffix=B "${iso_estimate_bytes}" 2>/dev/null || echo "${iso_estimate_bytes} bytes")
echo "Prototype A estimated ISO size (rootfs + 200M ESP/overhead): ${iso_estimate_human}"
echo "Prototype A disk avail: ${avail_gb}G, 10G baseline budget: $((10*1024*1024*1024)) bytes"
if [[ "${avail_gb}" -lt 20 ]] || [[ "${PROTOTYPE_A_DRYRUN}" == "1" ]]; then
    echo "Prototype A dry-run mode: disk low or UTAH_ISO_DRYRUN=1, skipping 30G fallocate, estimation only"
fi

ESP_MB=$(( $(du -m "${INITRD}" | cut -f1) + $(du -m "${VMLINUZ}" | cut -f1) + 32 ))
ESP="${WORK}/efi.img"
truncate -s "${ESP_MB}M" "${ESP}"
mkfs.fat -F 32 -n ESP "${ESP}" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "${ESP}" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/images ::/images/pxeboot
# Prototype C: EFI/BOOT/BOOTX64.EFI is shim (Fedora/Microsoft signed),
# EFI/BOOT/grubx64.efi is GRUB second stage verified by shim.
mcopy -i "${ESP}" "${SHIM}" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${ESP}" "${GRUB}" ::/EFI/BOOT/grubx64.efi
mcopy -i "${ESP}" "${VMLINUZ}" ::/images/pxeboot/vmlinuz
mcopy -i "${ESP}" "${INITRD}" ::/images/pxeboot/initrd.img
# Documented exception (Issue #22): rootless podman unshare cannot write security.selinux
# xattrs into the squashfs root, leaving it unlabeled. enforcing=0 is required for live boot
# to avoid systemd/GDM denials until xattr-preserving rootfs assembly is implemented.
# GRUB live config: shim -> grub -> kernel. No loader entries; GRUB reads
# EFI/BOOT/grub.cfg on the ESP.
cat > "${WORK}/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
set prefix=(\$root)/EFI/BOOT
insmod blscfg
blscfg
EOF
cat > "${WORK}/utah-live.conf" <<EOF
 title   ${TITLE}
 linux   /images/pxeboot/vmlinuz
 initrd  /images/pxeboot/initrd.img
 options root=live:LABEL=${LABEL} rd.live.image rd.live.overlay.overlayfs=1 enforcing=0 console=ttyS0,115200n8
EOF
sed -i 's/^ //' "${WORK}/utah-live.conf"
printf 'timeout 5\ndefault utah-live.conf\n' > "${WORK}/loader.conf"
mcopy -i "${ESP}" "${WORK}/grub.cfg" ::/EFI/BOOT/grub.cfg
mcopy -i "${ESP}" "${WORK}/utah-live.conf" ::/loader/entries/utah-live.conf
mcopy -i "${ESP}" "${WORK}/loader.conf" ::/loader/loader.conf

# Assemble the ISO filesystem. Utah live media supports x86_64 UEFI boot via
# systemd-boot. BIOS/legacy MBR boot and file-backed/Ventoy loopback booting are
# unsupported; loopback configs and file-backed ISO boot parameters are deliberately omitted.
ISO_ROOT="${WORK}/iso-root"
mkdir -p "${ISO_ROOT}/EFI/BOOT" "${ISO_ROOT}/LiveOS" "${ISO_ROOT}/images/pxeboot"
cp "${SHIM}" "${ISO_ROOT}/EFI/BOOT/BOOTX64.EFI"
cp "${GRUB}" "${ISO_ROOT}/EFI/BOOT/grubx64.efi"
cp "${WORK}/grub.cfg" "${ISO_ROOT}/EFI/BOOT/grub.cfg"
cp "${VMLINUZ}" "${ISO_ROOT}/images/pxeboot/vmlinuz"
cp "${INITRD}" "${ISO_ROOT}/images/pxeboot/initrd.img"
cp "${ESP}" "${ISO_ROOT}/EFI/efi.img"
cp "${SQUASHFS}" "${ISO_ROOT}/LiveOS/squashfs.img"

xorriso -as mkisofs -iso-level 3 -r -J --joliet-long -V "${LABEL}" \
    --efi-boot EFI/efi.img -efi-boot-part --efi-boot-image \
    -o "${OUTPUT_ISO}" "${ISO_ROOT}"
echo "ISO ready: ${OUTPUT_ISO} ($(du -sh "${OUTPUT_ISO}" | cut -f1))"
# Budget guard: a silent drift of nearly a gigabyte in twelve days (#128) is
# exactly what this fails closed against. Compare byte counts so the GB ceiling
# is exact regardless of how `du -h` rounds.
iso_max_bytes=$(( ISO_MAX_GB * 1024 * 1024 * 1024 ))
iso_size_bytes=$(du -b "${OUTPUT_ISO}" | cut -f1)
if [ "${iso_size_bytes}" -gt "${iso_max_bytes}" ]; then
    echo "ERROR: live ISO ($(du -sh "${OUTPUT_ISO}" | cut -f1)) exceeds ${ISO_MAX_GB} GB budget (#128)" >&2
    exit 1
fi
ASSEMBLY
