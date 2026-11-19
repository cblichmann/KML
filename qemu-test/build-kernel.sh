#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Configure and build Linux 7.3-kml (x86_64 + PREEMPT_RT + Kernel Mode Linux).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARENT_DIR="$(cd "${REPO_DIR}/.." && pwd)"

if [[ -z "${KSRC:-}" ]]; then
	for candidate in "${PARENT_DIR}/linux-7.3" "${PARENT_DIR}/linux" "${REPO_DIR}/linux-7.3" "${REPO_DIR}/linux"; do
		if [[ -f "${candidate}/Makefile" ]]; then
			KSRC="${candidate}"
			break
		fi
	done
fi
KSRC="${KSRC:-${PARENT_DIR}/linux-7.3}"

if [[ -z "${KBUILD_DIR:-}" ]]; then
	if [[ -d "${PARENT_DIR}/build-x86_64" ]]; then
		KBUILD_DIR="${PARENT_DIR}/build-x86_64"
	else
		KBUILD_DIR="${REPO_DIR}/build-x86_64"
	fi
fi

JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "${KSRC}/Makefile" ]]; then
	echo "ERROR: Linux kernel source tree not found at ${KSRC}" >&2
	echo "Set KSRC=/path/to/linux-7.3 or clone Linux 7.3 next to this repository." >&2
	exit 1
fi

for tool in gcc make bc flex bison; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: Required build tool '${tool}' not found in PATH." >&2
		echo "Install prerequisites (e.g. apt-get install build-essential bc flex bison libelf-dev libssl-dev)." >&2
		exit 1
	fi
done

MAKE_EXTRA=()
if [[ -n "${HOSTCFLAGS:-}" ]]; then
	MAKE_EXTRA+=("HOSTCFLAGS=${HOSTCFLAGS}")
fi
if [[ -n "${HOSTLDFLAGS:-}" ]]; then
	MAKE_EXTRA+=("HOSTLDFLAGS=${HOSTLDFLAGS}")
fi

mkdir -p "${KBUILD_DIR}"

if [[ ! -f "${KBUILD_DIR}/.config" ]] || [[ "${RECONFIGURE:-0}" == "1" ]]; then
	echo "[*] Generating x86_64_defconfig + KML + PREEMPT_RT in ${KBUILD_DIR}..."
	make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" x86_64_defconfig

	"${KSRC}/scripts/config" --file "${KBUILD_DIR}/.config" \
		-e EXPERT \
		-e PREEMPT_RT \
		-d MITIGATION_PAGE_TABLE_ISOLATION \
		-d X86_FRED \
		-d XEN \
		-d XEN_PV \
		-e KERNEL_MODE_LINUX \
		-e KML_CHECK_CHROOT \
		-e FTRACE \
		-e FUNCTION_TRACER \
		-e DEBUG_FS \
		-e KALLSYMS \
		-e KALLSYMS_ALL \
		-e GDB_SCRIPTS \
		-e VIRTIO_PCI \
		-e VIRTIO_BLK \
		-e VIRTIO_NET \
		-e NET_9P \
		-e NET_9P_VIRTIO \
		-e 9P_FS

	make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" olddefconfig
fi

echo "[*] Building bzImage (${JOBS} jobs)..."
make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" bzImage

echo "[+] Kernel ready: ${KBUILD_DIR}/arch/x86/boot/bzImage"
echo "[+] KML vDSO:     ${KBUILD_DIR}/arch/x86/entry/vdso/vdso64/vdso64.so"
