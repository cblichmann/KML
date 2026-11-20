#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Boot Linux 7.3-kml in QEMU (x86_64 or aarch64; defaults to TCG software emulation).

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
ACCEL="${QEMU_ACCEL:-tcg}"
CPU_MODEL="${QEMU_CPU:-}"
SMP="${QEMU_SMP:-2}"
MEM="${QEMU_MEM:-512M}"
MODE="interactive"
GDB_ARGS=()
EXTRA_CMDLINE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --arch {x86_64,aarch64}  Target guest architecture (default: ${ARCH})
  --test                   Run automated KML verification & benchmark suite and exit
  --kvm                    Use KVM hardware acceleration instead of TCG emulation
  --tcg                    Use QEMU TCG software emulation (default; VM-safe)
  --smp N                  Number of guest vCPUs (default: ${SMP})
  --mem SIZE               Guest RAM size (default: ${MEM})
  --gdb                    Listen for GDB on tcp::1234 and pause at boot (-s -S)
  --append STR             Extra kernel command-line parameters
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--arch)
			ARCH="$2"
			shift 2
			;;
		--test)
			MODE="test"
			shift
			;;
		--kvm)
			ACCEL="kvm"
			shift
			;;
		--tcg)
			ACCEL="tcg"
			shift
			;;
		--smp)
			SMP="$2"
			shift 2
			;;
		--mem)
			MEM="$2"
			shift 2
			;;
		--gdb)
			GDB_ARGS=(-s -S)
			shift
			;;
		--append)
			EXTRA_CMDLINE="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
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

if [[ "${ARCH}" == "x86_64" ]]; then
	IMG_REL="arch/x86/boot/bzImage"
else
	IMG_REL="arch/arm64/boot/Image"
fi

if [[ -z "${KBUILD_DIR:-}" ]]; then
	if [[ -f "${REPO_DIR}/build-${ARCH}/${IMG_REL}" ]]; then
		KBUILD_DIR="${REPO_DIR}/build-${ARCH}"
	else
		KBUILD_DIR="${PARENT_DIR}/build-${ARCH}"
	fi
fi

if [[ "${ARCH}" == "x86_64" ]]; then
	KERNEL_IMAGE="${BZIMAGE:-${KERNEL_IMAGE:-${KBUILD_DIR}/${IMG_REL}}}"
else
	KERNEL_IMAGE="${KERNEL_IMAGE:-${KBUILD_DIR}/${IMG_REL}}"
fi
INITRAMFS="${INITRAMFS:-${SCRIPT_DIR}/out/initramfs-${ARCH}.cpio.gz}"

if [[ ! -f "${KERNEL_IMAGE}" ]]; then
	echo "[*] Kernel image not found at ${KERNEL_IMAGE}; building via build-kernel.sh --arch ${ARCH}..."
	KBUILD_DIR="${KBUILD_DIR}" "${SCRIPT_DIR}/build-kernel.sh" --arch "${ARCH}"
fi

if [[ ! -f "${INITRAMFS}" ]]; then
	echo "[*] Initramfs not found at ${INITRAMFS}; building via build-initramfs.sh --arch ${ARCH}..."
	KBUILD_DIR="${KBUILD_DIR}" INITRAMFS="${INITRAMFS}" "${SCRIPT_DIR}/build-initramfs.sh" --arch "${ARCH}"
fi

if [[ "${ARCH}" == "x86_64" ]]; then
	QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
	MACHINE_ARG="q35,accel=${ACCEL}"
	if [[ -z "${CPU_MODEL}" ]]; then
		CPU_MODEL="$([[ "${ACCEL}" == "kvm" ]] && echo "host" || echo "max")"
	fi
	CMDLINE="console=ttyS0 earlyprintk=serial nokaslr panic=-1"
else
	QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
	if [[ "${ACCEL}" == "kvm" ]]; then
		MACHINE_ARG="virt,accel=kvm,gic-version=host"
		CPU_MODEL="${CPU_MODEL:-host}"
	else
		MACHINE_ARG="virt,accel=tcg"
		CPU_MODEL="${CPU_MODEL:-max,pauth-impdef=on}"
	fi
	CMDLINE="console=ttyAMA0 earlycon nokaslr panic=-1"
fi

if [[ "${MODE}" == "test" ]]; then
	CMDLINE="${CMDLINE} kml.selftest=1"
fi
if [[ -n "${EXTRA_CMDLINE}" ]]; then
	CMDLINE="${CMDLINE} ${EXTRA_CMDLINE}"
fi

QEMU_CMD=(
	"${QEMU_BIN}"
	-machine "${MACHINE_ARG}"
	-cpu "${CPU_MODEL}"
	-smp "${SMP}"
	-m "${MEM}"
	-nographic
	-no-reboot
	-kernel "${KERNEL_IMAGE}"
	-initrd "${INITRAMFS}"
	-append "${CMDLINE}"
	"${GDB_ARGS[@]}"
)

echo "[*] Launching QEMU (${ARCH}, accel=${ACCEL}, cpu=${CPU_MODEL}, smp=${SMP}, mem=${MEM}, mode=${MODE})..."

if [[ "${MODE}" == "test" ]]; then
	mkdir -p "${SCRIPT_DIR}/out"
	LOG_FILE="${SCRIPT_DIR}/out/selftest-${ARCH}.log"
	"${QEMU_CMD[@]}" 2>&1 | tee "${LOG_FILE}"
	ln -sf "$(basename "${LOG_FILE}")" "${SCRIPT_DIR}/out/selftest.log"
	if grep -q "=== ALL KML TESTS PASSED ===" "${LOG_FILE}"; then
		echo "[+] Automated QEMU KML verification (${ARCH}) succeeded."
		exit 0
	else
		echo "[-] Automated QEMU KML verification (${ARCH}) failed! See ${LOG_FILE}" >&2
		exit 1
	fi
else
	exec "${QEMU_CMD[@]}"
fi
