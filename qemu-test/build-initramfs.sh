#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build KML test binaries (linked against the kernel vDSO) and package initramfs.

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

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --arch {x86_64,aarch64}  Target guest architecture (default: ${ARCH})
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--arch)
			ARCH="$2"
			shift 2
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

if [[ "${ARCH}" == "x86_64" ]]; then
	VDSO_REL="arch/x86/entry/vdso/vdso64/vdso64.so"
	EXPECTED_ELF_MACH="Advanced Micro Devices X86-64"
else
	VDSO_REL="arch/arm64/kernel/vdso/vdso.so"
	EXPECTED_ELF_MACH="AArch64"
fi

if [[ -z "${KBUILD_DIR:-}" ]]; then
	if [[ -f "${REPO_DIR}/build-${ARCH}/${VDSO_REL}" ]]; then
		KBUILD_DIR="${REPO_DIR}/build-${ARCH}"
	else
		KBUILD_DIR="${PARENT_DIR}/build-${ARCH}"
	fi
fi

VDSO_SO="${VDSO_SO:-${KBUILD_DIR}/${VDSO_REL}}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out}"
BIN_DIR="${OUT_DIR}/bin-${ARCH}"
INITRAMFS="${INITRAMFS:-${OUT_DIR}/initramfs-${ARCH}.cpio.gz}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "${VDSO_SO}" ]]; then
	echo "ERROR: vDSO shared object not found at ${VDSO_SO}" >&2
	echo "Build the kernel first (./build-kernel.sh --arch ${ARCH})." >&2
	exit 1
fi

READELF_BIN="$(command -v llvm-readelf || command -v readelf)"
NM_BIN="$(command -v llvm-nm || command -v nm)"

elf_matches_arch() {
	local bin="$1"
	[[ -f "${bin}" && -x "${bin}" ]] || return 1
	"${READELF_BIN}" -h "${bin}" 2>/dev/null | grep -q "Machine:.*${EXPECTED_ELF_MACH}"
}

normalize_host_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo "x86_64" ;;
		aarch64|arm64) echo "aarch64" ;;
		*) uname -m ;;
	esac
}

HOST_ARCH="$(normalize_host_arch)"
mkdir -p "${OUT_DIR}" "${BIN_DIR}"
STAGE_DIR="$(mktemp -d "${OUT_DIR}/rootfs.${ARCH}.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT

copy_host_shared_deps() {
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

build_musl_aarch64_sysroot() {
	local prefix="${OUT_DIR}/musl-aarch64"
	if [[ -f "${prefix}/lib/libc.so" && -f "${prefix}/lib/Scrt1.o" ]]; then
		echo "${prefix}"
		return 0
	fi

	local musl_src="${MUSL_SRC:-}"
	if [[ -z "${musl_src}" ]]; then
		for cand in "${PARENT_DIR}/vendor/musl" "${REPO_DIR}/vendor/musl" "/usr/src/musl"; do
			if [[ -f "${cand}/configure" ]]; then
				musl_src="${cand}"
				break
			fi
		done
	fi
	if [[ -z "${musl_src}" || ! -f "${musl_src}/configure" ]]; then
		echo "ERROR: Cross-compiling aarch64 initramfs without aarch64-linux-gnu-gcc requires musl sources (MUSL_SRC)." >&2
		exit 1
	fi

	local libgcc_a=""
	for cand in \
		"${PARENT_DIR}"/vendor/tools/host/usr/lib/gcc-cross/aarch64-linux-gnu/*/libgcc.a \
		/usr/lib/gcc-cross/aarch64-linux-gnu/*/libgcc.a \
		"${PARENT_DIR}"/vendor/tools/llvm/lib/clang/*/lib/aarch64-*/libclang_rt.builtins.a; do
		if [[ -f "${cand}" ]]; then
			libgcc_a="${cand}"
			break
		fi
	done
	if [[ -z "${libgcc_a}" ]]; then
		echo "ERROR: Could not locate aarch64 libgcc.a or libclang_rt.builtins.a." >&2
		exit 1
	fi

	echo "[*] Building dynamic musl aarch64 runtime (ld-musl-aarch64.so.1) in ${prefix}..." >&2
	local workdir
	workdir="$(mktemp -d "${OUT_DIR}/musl-build.XXXXXX")"
	cp -a "${musl_src}" "${workdir}/src"

	# Register kernel-mapped [vdso] (AT_SYSINFO_EHDR) as linux-vdso.so.1 before
	# DT_NEEDED resolution so binaries linked against vdso.so resolve [vdso]
	# symbols ahead of libc.so, matching glibc ld-linux semantics.
	python3 - "${workdir}/src/ldso/dynlink.c" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
vdso_orig = """\t/* Attach to vdso, if provided by the kernel, last so that it does
\t * not become part of the global namespace.  */
\tif (search_vec(auxv, &vdso_base, AT_SYSINFO_EHDR) && vdso_base) {
\t\tEhdr *ehdr = (void *)vdso_base;
\t\tPhdr *phdr = vdso.phdr = (void *)(vdso_base + ehdr->e_phoff);
\t\tvdso.phnum = ehdr->e_phnum;
\t\tvdso.phentsize = ehdr->e_phentsize;
\t\tfor (i=ehdr->e_phnum; i; i--, phdr=(void *)((char *)phdr + ehdr->e_phentsize)) {
\t\t\tif (phdr->p_type == PT_DYNAMIC)
\t\t\t\tvdso.dynv = (void *)(vdso_base + phdr->p_offset);
\t\t\tif (phdr->p_type == PT_LOAD)
\t\t\t\tvdso.base = (void *)(vdso_base - phdr->p_vaddr + phdr->p_offset);
\t\t}
\t\tvdso.name = "";
\t\tvdso.shortname = "linux-gate.so.1";
\t\tvdso.relocated = 1;
\t\tvdso.deps = (struct dso **)no_deps;
\t\tdecode_dyn(&vdso);
\t\tvdso.prev = tail;
\t\ttail->next = &vdso;
\t\ttail = &vdso;
\t}"""
if vdso_orig not in src:
    raise SystemExit("ERROR: Expected AT_SYSINFO_EHDR block not found in musl ldso/dynlink.c")
src = src.replace(vdso_orig, "")
vdso_early = vdso_orig.replace(
    'vdso.shortname = "linux-gate.so.1";',
    'vdso.shortname = "linux-vdso.so.1";',
)
anchor = "\tif (env_preload) load_preload(env_preload);\n"
if anchor not in src:
    raise SystemExit("ERROR: Expected load_preload anchor not found in musl ldso/dynlink.c")
src = src.replace(anchor, anchor + vdso_early + "\n", 1)
p.write_text(src, encoding="utf-8")
PY

	mkdir -p "${workdir}/build"
	(
		cd "${workdir}/build"
		CC="clang --target=aarch64-linux-musl -fuse-ld=lld" \
		AR="llvm-ar" \
		RANLIB="llvm-ranlib" \
		LIBCC="${libgcc_a}" \
		CFLAGS="-O2 -march=armv8-a" \
		"${workdir}/src/configure" \
			--target=aarch64-linux-musl \
			--prefix="${prefix}" \
			--syslibdir=/lib \
			--disable-static \
			--disable-wrapper >&2
		make -j"${JOBS}" >&2
		rm -rf "${prefix}"
		make install >&2
	)
	rm -rf "${workdir}"

	cp -f "${libgcc_a}" "${prefix}/lib/libgcc.a"

	local uapi_inc=""
	for cand in \
		"${PARENT_DIR}/vendor/tools/host/usr/aarch64-linux-gnu/include" \
		"/usr/aarch64-linux-gnu/include"; do
		if [[ -d "${cand}/linux" && -d "${cand}/asm" ]]; then
			uapi_inc="${cand}"
			break
		fi
	done
	if [[ -n "${uapi_inc}" ]]; then
		cp -rL "${uapi_inc}/linux" "${prefix}/include/"
		cp -rL "${uapi_inc}/asm-generic" "${prefix}/include/"
		cp -rL "${uapi_inc}/asm" "${prefix}/include/"
	else
		local ksrc="${KSRC:-${PARENT_DIR}/linux-7.3}"
		make -C "${ksrc}" ARCH=arm64 INSTALL_HDR_PATH="${prefix}" headers_install >&2
	fi

	echo "${prefix}"
}

TOOLCHAIN_MODE=""
MUSL_PREFIX=""
CROSS_SYSROOT=""

if [[ "${HOST_ARCH}" == "${ARCH}" ]] && command -v gcc >/dev/null 2>&1; then
	TOOLCHAIN_MODE="native-gcc"
elif [[ "${ARCH}" == "aarch64" ]] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	TOOLCHAIN_MODE="cross-gnu-gcc"
	CROSS_SYSROOT="$(aarch64-linux-gnu-gcc -print-sysroot 2>/dev/null || true)"
	if [[ -z "${CROSS_SYSROOT}" || "${CROSS_SYSROOT}" == "/" ]]; then
		CROSS_SYSROOT="/usr/aarch64-linux-gnu"
	fi
elif [[ "${ARCH}" == "aarch64" ]] && command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
	TOOLCHAIN_MODE="clang-musl"
	MUSL_PREFIX="$(build_musl_aarch64_sysroot)"
else
	echo "ERROR: No suitable compiler found for target architecture '${ARCH}'." >&2
	exit 1
fi

compile_target_bin() {
	local src_file="$1"
	local out_bin="$2"
	local with_vdso="$3"
	local vdso_args=()
	if [[ "${with_vdso}" == "1" ]]; then
		vdso_args=(-Wl,--no-as-needed "${VDSO_SO}" -Wl,--as-needed)
	fi

	case "${TOOLCHAIN_MODE}" in
		native-gcc)
			gcc -O2 -Wall -Wextra "${src_file}" "${vdso_args[@]}" -o "${out_bin}"
			;;
		cross-gnu-gcc)
			aarch64-linux-gnu-gcc -O2 -Wall -Wextra "${src_file}" "${vdso_args[@]}" -o "${out_bin}"
			;;
		clang-musl)
			clang --target=aarch64-linux-musl -fuse-ld=lld -O2 -Wall -Wextra \
				-march=armv8-a -fPIE -pie \
				-nostdinc -isystem "${MUSL_PREFIX}/include" \
				-nostdlib \
				-Wl,-dynamic-linker,/lib/ld-musl-aarch64.so.1 \
				"${MUSL_PREFIX}/lib/Scrt1.o" \
				"${MUSL_PREFIX}/lib/crti.o" \
				"${src_file}" \
				"${vdso_args[@]}" \
				-L"${MUSL_PREFIX}/lib" -lc \
				"${MUSL_PREFIX}/lib/libgcc.a" \
				"${MUSL_PREFIX}/lib/crtn.o" \
				-o "${out_bin}"
			;;
	esac
}

install_runtime_libs() {
	local bin="$1"
	local dest_root="$2"
	case "${TOOLCHAIN_MODE}" in
		native-gcc)
			copy_host_shared_deps "${bin}" "${dest_root}"
			;;
		cross-gnu-gcc)
			mkdir -p "${dest_root}/lib" "${dest_root}/lib64"
			for lib in "${CROSS_SYSROOT}"/lib/ld-linux-aarch64.so.* "${CROSS_SYSROOT}"/lib/libc.so.* "${CROSS_SYSROOT}"/lib/libm.so.* "${CROSS_SYSROOT}"/lib/libpthread.so.* "${CROSS_SYSROOT}"/lib/librt.so.*; do
				[[ -e "${lib}" ]] || continue
				cp -Lf "${lib}" "${dest_root}/lib/"
			done
			;;
		clang-musl)
			mkdir -p "${dest_root}/lib"
			cp -Lf "${MUSL_PREFIX}/lib/libc.so" "${dest_root}/lib/ld-musl-aarch64.so.1"
			chmod 0755 "${dest_root}/lib/ld-musl-aarch64.so.1"
			ln -sf ld-musl-aarch64.so.1 "${dest_root}/lib/libc.so"
			;;
	esac
}

echo "[*] Compiling KML ${ARCH} user-space binaries (${TOOLCHAIN_MODE}) against ${VDSO_SO}..."
for prog in kml_test kml_bench hello_kml; do
	compile_target_bin "${SCRIPT_DIR}/src/${prog}.c" "${BIN_DIR}/${prog}" 1
done

echo "[*] Verifying LINUX_2.6* vDSO symbol bindings in kml_test (${ARCH}):"
"${NM_BIN}" -D "${BIN_DIR}/kml_test" | grep -E 'LINUX_2\.6' || {
	echo "ERROR: Expected LINUX_2.6* symbols not bound in kml_test!" >&2
	exit 1
}

echo "[*] Populating ${ARCH} initramfs staging directory..."
mkdir -p "${STAGE_DIR}"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,etc,trusted,chroot_jail/trusted}
chmod 1777 "${STAGE_DIR}/tmp"

for prog in kml_test kml_bench hello_kml; do
	cp -f "${BIN_DIR}/${prog}" "${STAGE_DIR}/trusted/${prog}"
	chmod 0755 "${STAGE_DIR}/trusted/${prog}"
done
cp -f "${BIN_DIR}/kml_test" "${STAGE_DIR}/bin/kml_test"
cp -f "${BIN_DIR}/kml_bench" "${STAGE_DIR}/bin/kml_bench"
chmod 0755 "${STAGE_DIR}/bin/kml_test" "${STAGE_DIR}/bin/kml_bench"
install_runtime_libs "${BIN_DIR}/kml_test" "${STAGE_DIR}"

cp -f "${BIN_DIR}/kml_test" "${STAGE_DIR}/chroot_jail/trusted/kml_test"
chmod 0755 "${STAGE_DIR}/chroot_jail/trusted/kml_test"
install_runtime_libs "${BIN_DIR}/kml_test" "${STAGE_DIR}/chroot_jail"

BUSYBOX_CANDIDATE="${BUSYBOX_BIN:-$(command -v busybox || true)}"
if [[ -n "${BUSYBOX_CANDIDATE}" ]] && elf_matches_arch "${BUSYBOX_CANDIDATE}"; then
	cp -Lf "${BUSYBOX_CANDIDATE}" "${STAGE_DIR}/bin/busybox"
	chmod 0755 "${STAGE_DIR}/bin/busybox"
	if [[ "${HOST_ARCH}" == "${ARCH}" ]]; then
		copy_host_shared_deps "${STAGE_DIR}/bin/busybox" "${STAGE_DIR}"
	fi

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
	echo "--- [1/5] Untrusted binary (/bin/kml_test -> expect user mode) ---"
	/bin/kml_test --expect-user || FAIL=1

	echo ""
	echo "--- [2/5] Chrooted /trusted binary (CONFIG_KML_CHECK_CHROOT -> expect user mode) ---"
	chroot /chroot_jail /trusted/kml_test --expect-chroot-user || FAIL=1

	echo ""
	echo "--- [3/5] Trusted KML binary (/trusted/kml_test -> expect kernel mode) ---"
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
echo "  /trusted/hello_kml      # Run minimal demo in Kernel Mode"
echo "  /bin/kml_test           # Show privilege in User Mode"
echo "  /trusted/kml_test       # Show privilege in Kernel Mode"
echo "  /trusted/kml_test --expect-kernel"
echo "  /trusted/kml_bench 200000"
echo "  poweroff -f             # Exit QEMU cleanly"
echo ""

exec setsid cttyhack /bin/sh
EOF
	chmod 0755 "${STAGE_DIR}/init"
else
	echo "[*] Target-arch busybox not found; compiling standalone C /init (${ARCH})..."
	compile_target_bin "${SCRIPT_DIR}/src/kml_init.c" "${BIN_DIR}/kml_init" 0
	cp -f "${BIN_DIR}/kml_init" "${STAGE_DIR}/init"
	chmod 0755 "${STAGE_DIR}/init"
fi

(
	cd "${STAGE_DIR}"
	find . -print0 | cpio --null --create --format=newc --quiet | gzip -9 > "${INITRAMFS}"
)
ln -sf "$(basename "${INITRAMFS}")" "${OUT_DIR}/initramfs.cpio.gz"

echo "[+] Built ${ARCH} initramfs: ${INITRAMFS} ($(du -h "${INITRAMFS}" | cut -f1))"
