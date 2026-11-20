#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Configure and build Linux 7.3-kml (x86_64 or aarch64 + PREEMPT_RT + Kernel Mode Linux).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARENT_DIR="$(cd "${REPO_DIR}/.." && pwd)"

for env_candidate in "${PARENT_DIR}/vendor/env.sh" "${REPO_DIR}/vendor/env.sh"; do
	if [[ -f "${env_candidate}" ]]; then
		# shellcheck disable=SC1090
		source "${env_candidate}"
		break
	fi
done

ARCH="${KML_ARCH:-x86_64}"
RECONFIGURE="${RECONFIGURE:-0}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --arch {x86_64,aarch64}  Target kernel architecture (default: ${ARCH})
  --reconfigure            Regenerate .config before building
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--arch)
			ARCH="$2"
			shift 2
			;;
		--reconfigure)
			RECONFIGURE=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown option '$1'" >&2
			usage >&2
			exit 1
			;;
	esac
done

case "${ARCH}" in
	x86_64|amd64) ARCH="x86_64" ;;
	aarch64|arm64) ARCH="aarch64" ;;
	*)
		echo "ERROR: Unsupported architecture '${ARCH}' (expected x86_64 or aarch64)." >&2
		exit 1
		;;
esac

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
	if [[ -d "${PARENT_DIR}/build-${ARCH}" || -d "${PARENT_DIR}/linux-7.3" ]]; then
		KBUILD_DIR="${PARENT_DIR}/build-${ARCH}"
	else
		KBUILD_DIR="${REPO_DIR}/build-${ARCH}"
	fi
fi

JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "${KSRC}/Makefile" ]]; then
	echo "ERROR: Linux kernel source tree not found at ${KSRC}" >&2
	echo "Set KSRC=/path/to/linux-7.3 or clone Linux 7.3 next to this repository." >&2
	exit 1
fi

for tool in make bc flex bison; do
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

if [[ "${ARCH}" == "x86_64" ]]; then
	if [[ "${LLVM:-0}" == "1" ]] || ! command -v gcc >/dev/null 2>&1; then
		MAKE_EXTRA+=("LLVM=1")
	fi

	if [[ ! -f "${KBUILD_DIR}/.config" ]] || [[ "${RECONFIGURE}" == "1" ]]; then
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

	echo "[*] Building x86_64 bzImage (${JOBS} jobs)..."
	make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" bzImage

	echo "[+] Kernel ready: ${KBUILD_DIR}/arch/x86/boot/bzImage"
	echo "[+] KML vDSO:     ${KBUILD_DIR}/arch/x86/entry/vdso/vdso64/vdso64.so"
else
	MAKE_EXTRA+=("ARCH=arm64")
	if [[ "${LLVM:-}" == "1" ]] || { command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; }; then
		MAKE_EXTRA+=("LLVM=1")
	elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
		MAKE_EXTRA+=("CROSS_COMPILE=aarch64-linux-gnu-")
	elif [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
		echo "ERROR: Building arm64 kernel requires clang+lld (LLVM=1) or aarch64-linux-gnu-gcc." >&2
		exit 1
	fi

	if [[ ! -f "${KBUILD_DIR}/.config" ]] || [[ "${RECONFIGURE}" == "1" ]]; then
		echo "[*] Generating arm64 defconfig + KML + PREEMPT_RT in ${KBUILD_DIR}..."
		make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" defconfig

		"${KSRC}/scripts/config" --file "${KBUILD_DIR}/.config" \
			-e EXPERT \
			-e PREEMPT_RT \
			-d UNMAP_KERNEL_AT_EL0 \
			-d ARM64_PAN \
			-d ARM64_EPAN \
			-d ARM64_SW_TTBR0_PAN \
			-d ARM64_PIE \
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

	echo "[*] Building arm64 Image (${JOBS} jobs)..."
	make -C "${KSRC}" O="${KBUILD_DIR}" "${MAKE_EXTRA[@]}" -j"${JOBS}" Image

	echo "[+] Kernel ready: ${KBUILD_DIR}/arch/arm64/boot/Image"
	echo "[+] KML vDSO:     ${KBUILD_DIR}/arch/arm64/kernel/vdso/vdso.so"
fi
