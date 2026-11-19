# Kernel Mode Linux (KML) for Linux 7.3

Kernel Mode Linux (KML) executes trusted user-space ELF binaries (placed under `/trusted/`) at the CPU's kernel privilege level—**Ring 0 (`CPL=0`) on `x86_64`** and **`SYSTEM_MODE` on 32-bit `arm`**—so user processes retain standard virtual memory, demand paging, signals, `fork()`, and `PREEMPT_RT` scheduling while accessing kernel address space and invoking kernel functions directly without hardware privilege transitions.

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

# 3. Build the x86_64 PREEMPT_RT + KML kernel, build the initramfs, and run the QEMU TCG test suite
cd qemu-test
./build-kernel.sh
./build-initramfs.sh
./run-qemu.sh --test

# 4. Or boot an interactive guest shell in QEMU TCG software emulation mode (VM-safe, no KVM required)
./run-qemu.sh
```

---

## Repository Contents

| Path | Description |
| :--- | :--- |
| `0001-Integrate-KML.patch` | Core KML integration for Linux 7.3 (`x86_64` Ring 0 + 32-bit `arm` `SYSTEM_MODE`, `TIF_KU` kernel-pointer `uaccess`, `/trusted/` loader with `chroot` guard, `IST_INDEX_KML` exception/IRQ stack switching). |
| `0002-Use-VDSO-as-the-wrapper-for-KML-resource.patch` | KML vDSO direct-call wrappers (`clock_gettime`, `gettimeofday`, `sched_yield`, `nanosleep`, `kernel_sched_timeout`, `trace_call_by_kml`, `kml_syscall`, `kml_call`) via `vdso_time_data` and `kml_trampoline`. |
| `qemu-test/` | Turnkey `x86_64` QEMU test, demo, and microbenchmark suite (defaults to `-machine q35,accel=tcg` software emulation). |
| `LICENSE` | GNU General Public License v2.0. |

---

## Kernel Configuration

### `x86_64` (`qemu-test/build-kernel.sh` configures these automatically)

- `CONFIG_EXPERT=y`
- `CONFIG_PREEMPT_RT=y` *(optional, recommended for real-time workloads)*
- `CONFIG_MITIGATION_PAGE_TABLE_ISOLATION=n` *(required so Ring-0 user processes share unified page tables)*
- `CONFIG_X86_FRED=n` and `CONFIG_XEN_PV=n`
- `CONFIG_KERNEL_MODE_LINUX=y`
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

Rather than hardcoding `vmlinux` symbol addresses, link user programs against the built vDSO shared object (`build-x86_64/arch/x86/entry/vdso/vdso64/vdso64.so` on `x86_64`, or `arch/arm/vdso/vdso.so` on `arm`):

```bash
VDSO_SO=../build-x86_64/arch/x86/entry/vdso/vdso64/vdso64.so

gcc -O2 my_kml_app.c \
  -Wl,--no-as-needed "${VDSO_SO}" -Wl,--as-needed \
  -o my_kml_app
```

Verify that symbols bind to version `LINUX_2.6` (resolved from `[vdso]` at runtime):

```shell-session
$ nm -D my_kml_app | grep LINUX_2.6
                 U clock_gettime@LINUX_2.6
                 U kernel_sched_timeout@LINUX_2.6
                 U trace_call_by_kml@LINUX_2.6
```

Install the executable under `/trusted/my_kml_app` on the root filesystem:
- Running `/trusted/my_kml_app` launches it in **Ring 0 (`CPL=0`)**, where vDSO wrappers invoke kernel routines directly on `current`'s kernel stack via `kml_trampoline` (preserving `%cs` across `PREEMPT_RT` sleeps and SMP CPU migrations).
- Running the exact same binary outside `/trusted/` (or inside a `chroot` jail when `CONFIG_KML_CHECK_CHROOT=y`) runs it in **Ring 3 (`CPL=3`)**, where standard vDSO timekeeping remains active and KML-only entry points safely return `-EPERM`.
