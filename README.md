# Kernel Mode Linux (KML) for Linux 7.3

Kernel Mode Linux (KML) executes trusted user-space ELF binaries (placed under `/trusted/`) at the CPU's kernel privilege level—**Ring 0 (`CPL=0`) on `x86_64`**, **`EL1t` (`SPSel=0`) on `AArch64` (`arm64`)**, and **`SYSTEM_MODE` on 32-bit `arm`**—so user processes retain standard virtual memory, demand paging, signals, `fork()`, and `PREEMPT_RT` scheduling while accessing kernel address space and invoking kernel functions directly without hardware privilege transitions.

---

## TL;DR — How to Apply & Run (Linux 7.3)

Mainline Linux 7.3 already integrates `PREEMPT_RT` natively (`CONFIG_PREEMPT_RT=y`, merged upstream in Linux 6.12), so no external `-rt` patchset is needed.

```shell-session
# 1. Clone this repository and mainline Linux 7.3 side-by-side
git clone git@github.com:cblichmann/KML.git
git clone -b v7.3 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux-7.3

# 2. Apply the two KML patches
cd linux-7.3
git am ../KML/*.patch
cd ../KML

# 3a. Build & test x86_64 (Ring 0) in QEMU TCG mode
cd qemu-test
./build-kernel.sh --arch x86_64
./build-initramfs.sh --arch x86_64
./run-qemu.sh --arch x86_64 --test

# 3b. Build & test AArch64 (EL1t) in QEMU TCG mode
./build-kernel.sh --arch aarch64
./build-initramfs.sh --arch aarch64
./run-qemu.sh --arch aarch64 --test

# 4. Or boot an interactive guest shell in QEMU TCG software emulation mode (VM-safe, no KVM required)
./run-qemu.sh --arch x86_64
./run-qemu.sh --arch aarch64
```

---

## Repository Contents

| Path | Description |
| :--- | :--- |
| `0001-Integrate-KML.patch` | Core KML integration for Linux 7.3 (`x86_64` Ring 0, `AArch64` `EL1t` / `SPSel=0`, and 32-bit `arm` `SYSTEM_MODE`; `TIF_KU` kernel-pointer `uaccess`; `/trusted/` loader with `chroot` guard; `IST_INDEX_KML` / `SP_EL1` exception & IRQ stack switching). |
| `0002-Use-VDSO-as-the-wrapper-for-KML-resource.patch` | KML vDSO direct-call wrappers (`clock_gettime`, `gettimeofday`, `sched_yield`, `nanosleep`, `kernel_sched_timeout`, `trace_call_by_kml`, `kml_syscall`, `kml_call`) via `vdso_time_data` and `kml_trampoline` on `x86_64`, `AArch64`, and `arm`. |
| `qemu-test/` | Turnkey `x86_64` & `aarch64` QEMU test, demo, and microbenchmark suite (defaults to QEMU TCG software emulation). |
| `LICENSE` | GNU General Public License v2.0. |

---

## Kernel Configuration

### `x86_64` (`qemu-test/build-kernel.sh --arch x86_64` configures these automatically)

- `CONFIG_EXPERT=y`
- `CONFIG_PREEMPT_RT=y` *(optional, recommended for real-time workloads)*
- `CONFIG_MITIGATION_PAGE_TABLE_ISOLATION=n` *(required so Ring-0 user processes share unified page tables)*
- `CONFIG_X86_FRED=n` and `CONFIG_XEN_PV=n`
- `CONFIG_KERNEL_MODE_LINUX=y`
- `CONFIG_KML_CHECK_CHROOT=y`

### `arm64` / `AArch64` (`qemu-test/build-kernel.sh --arch aarch64` configures these automatically)

- `CONFIG_EXPERT=y`
- `CONFIG_PREEMPT_RT=y` *(optional, recommended for real-time workloads)*
- `CONFIG_UNMAP_KERNEL_AT_EL0=n` *(required so `EL1t` user processes share unified `TTBR0`/`TTBR1` mappings)*
- `CONFIG_ARM64_PAN=n`, `CONFIG_ARM64_SW_TTBR0_PAN=n`, and `CONFIG_ARM64_PIE=n`
- `CONFIG_KERNEL_MODE_LINUX=y` *(automatically disables `CONFIG_ARM64_PTR_AUTH_KERNEL` while keeping user PAC compatible)*
- `CONFIG_KML_CHECK_CHROOT=y`

### `arm` (32-bit ARMv7, e.g. `multi_v7_defconfig`)

- `CONFIG_EXPERT=y`
- `CONFIG_ARM_LPAE=n`
- `CONFIG_ARM_PAN=n` *(disables `CONFIG_CPU_SW_DOMAIN_PAN` / `CONFIG_CPU_TTBR0_PAN`)*
- `CONFIG_VDSO=y`
- `CONFIG_KERNEL_MODE_LINUX=y`
- `CONFIG_KML_CHECK_CHROOT=y`

---

## Using the KML vDSO from User Programs

Rather than hardcoding `vmlinux` symbol addresses, link user programs against the built vDSO shared object (`build-x86_64/arch/x86/entry/vdso/vdso64/vdso64.so` on `x86_64`, `build-aarch64/arch/arm64/kernel/vdso/vdso.so` on `AArch64`, or `arch/arm/vdso/vdso.so` on `arm`):

```bash
# x86_64:
VDSO_SO=../build-x86_64/arch/x86/entry/vdso/vdso64/vdso64.so
gcc -O2 my_kml_app.c -Wl,--no-as-needed "${VDSO_SO}" -Wl,--as-needed -o my_kml_app

# AArch64:
VDSO_SO=../build-aarch64/arch/arm64/kernel/vdso/vdso.so
aarch64-linux-gnu-gcc -O2 my_kml_app.c -Wl,--no-as-needed "${VDSO_SO}" -Wl,--as-needed -o my_kml_app
```

Verify that symbols bind to version `LINUX_2.6` (`x86_64`/`arm`) or `LINUX_2.6.39` (`AArch64`), resolved from `[vdso]` at runtime:

```shell-session
$ nm -D my_kml_app | grep LINUX_2.6
                 U clock_gettime@LINUX_2.6
                 U kernel_sched_timeout@LINUX_2.6
                 U trace_call_by_kml@LINUX_2.6
```

Install the executable under `/trusted/my_kml_app` on the root filesystem:
- Running `/trusted/my_kml_app` launches it in **Ring 0 (`CPL=0` on `x86_64`)** or **`EL1t` (`SPSel=0` on `AArch64`)**, where vDSO wrappers invoke kernel routines directly on `current`'s kernel stack via `kml_trampoline` (preserving `%cs` / `EL1t` & `TPIDRRO_EL0` across `PREEMPT_RT` sleeps and SMP CPU migrations).
- Running the exact same binary outside `/trusted/` (or inside a `chroot` jail when `CONFIG_KML_CHECK_CHROOT=y`) runs it in **Ring 3 (`CPL=3`)** or **`EL0t`** (`TPIDRRO_EL0=0`, readable at `EL0` without traps), where standard vDSO counter timekeeping remains active and KML-only entry points safely return `-EPERM`.
