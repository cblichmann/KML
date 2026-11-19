#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Boot Linux 7.3-kml in QEMU (defaults to TCG software emulation so it runs inside VMs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARENT_DIR="$(cd "${REPO_DIR}/.." && pwd)"

if [[ -z "${KBUILD_DIR:-}" ]]; then
	if [[ -f "${REPO_DIR}/build-x86_64/arch/x86/boot/bzImage" ]]; then
		KBUILD_DIR="${REPO_DIR}/build-x86_64"
	else
		KBUILD_DIR="${PARENT_DIR}/build-x86_64"
	fi
fi

BZIMAGE="${BZIMAGE:-${KBUILD_DIR}/arch/x86/boot/bzImage}"
INITRAMFS="${INITRAMFS:-${SCRIPT_DIR}/out/initramfs.cpio.gz}"

ACCEL="${QEMU_ACCEL:-tcg}"
CPU_MODEL="${QEMU_CPU:-max}"
SMP="${QEMU_SMP:-2}"
MEM="${QEMU_MEM:-512M}"
MODE="interactive"
GDB_ARGS=()
EXTRA_CMDLINE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --test             Run automated KML verification & benchmark suite and exit
  --kvm              Use KVM hardware acceleration instead of TCG emulation
  --tcg              Use QEMU TCG software emulation (default; VM-safe)
  --smp N            Number of guest vCPUs (default: ${SMP})
  --mem SIZE         Guest RAM size (default: ${MEM})
  --gdb              Listen for GDB on tcp::1234 and pause at boot (-s -S)
  --append STR       Extra kernel command-line parameters
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--test)
			MODE="test"
			shift
			;;
		--kvm)
			ACCEL="kvm"
			CPU_MODEL="host"
			shift
			;;
		--tcg)
			ACCEL="tcg"
			CPU_MODEL="max"
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

if [[ ! -f "${BZIMAGE}" ]]; then
	echo "ERROR: Kernel image not found at ${BZIMAGE}" >&2
	echo "Run ./build-kernel.sh first." >&2
	exit 1
fi

if [[ ! -f "${INITRAMFS}" ]]; then
	echo "ERROR: Initramfs not found at ${INITRAMFS}" >&2
	echo "Run ./build-initramfs.sh first." >&2
	exit 1
fi

CMDLINE="console=ttyS0 earlyprintk=serial nokaslr panic=-1"
if [[ "${MODE}" == "test" ]]; then
	CMDLINE="${CMDLINE} kml.selftest=1"
fi
if [[ -n "${EXTRA_CMDLINE}" ]]; then
	CMDLINE="${CMDLINE} ${EXTRA_CMDLINE}"
fi

QEMU_CMD=(
	qemu-system-x86_64
	-machine "q35,accel=${ACCEL}"
	-cpu "${CPU_MODEL}"
	-smp "${SMP}"
	-m "${MEM}"
	-nographic
	-no-reboot
	-kernel "${BZIMAGE}"
	-initrd "${INITRAMFS}"
	-append "${CMDLINE}"
	"${GDB_ARGS[@]}"
)

echo "[*] Launching QEMU (accel=${ACCEL}, cpu=${CPU_MODEL}, smp=${SMP}, mem=${MEM}, mode=${MODE})..."

if [[ "${MODE}" == "test" ]]; then
	mkdir -p "${SCRIPT_DIR}/out"
	LOG_FILE="${SCRIPT_DIR}/out/selftest.log"
	"${QEMU_CMD[@]}" 2>&1 | tee "${LOG_FILE}"
	if grep -q "=== ALL KML TESTS PASSED ===" "${LOG_FILE}"; then
		echo "[+] Automated QEMU KML verification succeeded."
		exit 0
	else
		echo "[-] Automated QEMU KML verification failed! See ${LOG_FILE}" >&2
		exit 1
	fi
else
	exec "${QEMU_CMD[@]}"
fi
