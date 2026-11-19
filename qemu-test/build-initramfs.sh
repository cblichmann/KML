#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build KML test binaries (linked against vdso64.so) and package initramfs.cpio.gz.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARENT_DIR="$(cd "${REPO_DIR}/.." && pwd)"

if [[ -z "${KBUILD_DIR:-}" ]]; then
	if [[ -f "${REPO_DIR}/build-x86_64/arch/x86/entry/vdso/vdso64/vdso64.so" ]]; then
		KBUILD_DIR="${REPO_DIR}/build-x86_64"
	else
		KBUILD_DIR="${PARENT_DIR}/build-x86_64"
	fi
fi

VDSO_SO="${VDSO_SO:-${KBUILD_DIR}/arch/x86/entry/vdso/vdso64/vdso64.so}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out}"
INITRAMFS="${OUT_DIR}/initramfs.cpio.gz"

if [[ ! -f "${VDSO_SO}" ]]; then
	echo "ERROR: vDSO shared object not found at ${VDSO_SO}" >&2
	echo "Build the kernel first (./build-kernel.sh)." >&2
	exit 1
fi

BUSYBOX_BIN="${BUSYBOX_BIN:-$(command -v busybox)}"
if [[ -z "${BUSYBOX_BIN}" || ! -x "${BUSYBOX_BIN}" ]]; then
	echo "ERROR: busybox not found in PATH." >&2
	exit 1
fi

mkdir -p "${OUT_DIR}/bin"
STAGE_DIR="$(mktemp -d "${OUT_DIR}/rootfs.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT

echo "[*] Compiling KML user-space binaries against ${VDSO_SO}..."
for prog in kml_test kml_bench hello_kml; do
	gcc -O2 -Wall -Wextra \
		"${SCRIPT_DIR}/src/${prog}.c" \
		-Wl,--no-as-needed "${VDSO_SO}" -Wl,--as-needed \
		-o "${OUT_DIR}/bin/${prog}"
done

echo "[*] Verifying LINUX_2.6 vDSO symbol bindings in kml_test:"
nm -D "${OUT_DIR}/bin/kml_test" | grep -E 'LINUX_2\.6' || {
	echo "ERROR: Expected LINUX_2.6 symbols not bound in kml_test!" >&2
	exit 1
}

copy_shared_deps() {
	local bin="$1"
	local dest_root="$2"
	ldd "${bin}" | awk '{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^\//) print $i
		}
	}' | while read -r lib; do
		[[ -e "${lib}" ]] || continue
		local dir
		dir="${dest_root}$(dirname "${lib}")"
		mkdir -p "${dir}"
		cp -Lf "${lib}" "${dest_root}${lib}"
	done
}

echo "[*] Populating initramfs staging directory..."
mkdir -p "${STAGE_DIR}"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,etc,trusted,chroot_jail/trusted}
chmod 1777 "${STAGE_DIR}/tmp"

cp -Lf "${BUSYBOX_BIN}" "${STAGE_DIR}/bin/busybox"
chmod 0755 "${STAGE_DIR}/bin/busybox"
copy_shared_deps "${STAGE_DIR}/bin/busybox" "${STAGE_DIR}"

for prog in kml_test kml_bench hello_kml; do
	cp -f "${OUT_DIR}/bin/${prog}" "${STAGE_DIR}/trusted/${prog}"
	chmod 0755 "${STAGE_DIR}/trusted/${prog}"
done
cp -f "${OUT_DIR}/bin/kml_test" "${STAGE_DIR}/bin/kml_test"
cp -f "${OUT_DIR}/bin/kml_bench" "${STAGE_DIR}/bin/kml_bench"
chmod 0755 "${STAGE_DIR}/bin/kml_test" "${STAGE_DIR}/bin/kml_bench"
copy_shared_deps "${OUT_DIR}/bin/kml_test" "${STAGE_DIR}"

cp -f "${OUT_DIR}/bin/kml_test" "${STAGE_DIR}/chroot_jail/trusted/kml_test"
chmod 0755 "${STAGE_DIR}/chroot_jail/trusted/kml_test"
copy_shared_deps "${OUT_DIR}/bin/kml_test" "${STAGE_DIR}/chroot_jail"

cat > "${STAGE_DIR}/init" <<'EOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

/bin/busybox --install -s /bin 2>/dev/null || true
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /sys/kernel/debug /sys/kernel/tracing
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /dev/shm
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true

echo ""
echo "================================================================"
echo " Kernel Mode Linux (KML) Test Environment"
echo " Kernel: $(uname -srmv)"
echo "================================================================"

if grep -q "kml.selftest=1" /proc/cmdline; then
	echo "[*] Running automated KML verification suite..."
	FAIL=0

	echo ""
	echo "--- [1/5] Untrusted binary (/bin/kml_test -> expect Ring 3) ---"
	/bin/kml_test --expect-user || FAIL=1

	echo ""
	echo "--- [2/5] Chrooted /trusted binary (CONFIG_KML_CHECK_CHROOT -> expect Ring 3) ---"
	chroot /chroot_jail /trusted/kml_test --expect-chroot-user || FAIL=1

	echo ""
	echo "--- [3/5] Trusted KML binary (/trusted/kml_test -> expect Ring 0) ---"
	/trusted/kml_test --expect-kernel || FAIL=1

	echo ""
	echo "--- [4/5] Minimal KML tutorial binary (/trusted/hello_kml) ---"
	/trusted/hello_kml || FAIL=1

	echo ""
	echo "--- [5/5] Syscall vs KML vDSO Direct Call Microbenchmark ---"
	/bin/kml_bench 100000 || FAIL=1
	/trusted/kml_bench 100000 || FAIL=1

	echo ""
	if [ "$FAIL" -eq 0 ]; then
		echo "=== ALL KML TESTS PASSED ==="
	else
		echo "=== KML TEST SUITE FAILED ==="
	fi
	sync
	poweroff -f
	exit "$FAIL"
fi

echo ""
echo "Interactive shell ready. Useful commands:"
echo "  /trusted/hello_kml      # Run minimal demo in Ring 0 (Kernel Mode)"
echo "  /bin/kml_test           # Show CPL in Ring 3 (User Mode)"
echo "  /trusted/kml_test       # Show CPL in Ring 0 (Kernel Mode)"
echo "  /trusted/kml_test --expect-kernel"
echo "  /trusted/kml_bench 200000"
echo "  poweroff -f             # Exit QEMU cleanly"
echo ""

exec setsid cttyhack /bin/sh
EOF
chmod 0755 "${STAGE_DIR}/init"

(
	cd "${STAGE_DIR}"
	find . -print0 | cpio --null --create --format=newc --quiet | gzip -9 > "${INITRAMFS}"
)

echo "[+] Built initramfs: ${INITRAMFS} ($(du -h "${INITRAMFS}" | cut -f1))"
