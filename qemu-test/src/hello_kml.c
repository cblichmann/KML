// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal Kernel Mode Linux (KML) example program.
 *
 * When executed from /trusted/hello_kml, this program runs in CPU Ring 0
 * (x86_64 CPL=0) or EL1t (AArch64 SPSel=0) and invokes kernel functions
 * directly through the KML vDSO without software interrupts or privilege-level
 * context switches.
 */

#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

extern signed long kernel_sched_timeout(signed long timeout);
extern long trace_call_by_kml(void);

int main(void)
{
	struct timespec ts;
	int in_kernel = 0;

#if defined(__x86_64__)
	uint16_t cs;

	__asm__ volatile("mov %%cs, %0" : "=r"(cs));
	in_kernel = ((cs & 3) == 0);
	printf("hello_kml (pid=%d): CS=0x%04x, CPL=%d (%s)\n",
	       getpid(), cs, cs & 3,
	       in_kernel ? "Kernel Mode / Ring 0" : "User Mode / Ring 3");
#elif defined(__aarch64__)
	uint64_t tpidrro;

	__asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tpidrro));
	in_kernel = ((tpidrro & 1) != 0);
	if (in_kernel) {
		uint64_t el, spsel;

		__asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
		__asm__ volatile("mrs %0, SPSel" : "=r"(spsel));
		printf("hello_kml (pid=%d): CurrentEL=EL%lu, SPSel=%lu (Kernel Mode / EL1t)\n",
		       getpid(), (unsigned long)((el >> 2) & 3),
		       (unsigned long)(spsel & 1));
	} else {
		printf("hello_kml (pid=%d): TPIDRRO_EL0=0x%lx (User Mode / EL0t)\n",
		       getpid(), (unsigned long)tpidrro);
	}
#endif

	clock_gettime(CLOCK_MONOTONIC, &ts);
	printf("monotonic time via vDSO: %lld.%09ld s\n",
	       (long long)ts.tv_sec, ts.tv_nsec);

	if (in_kernel) {
		long rc = kernel_sched_timeout(2);

		trace_call_by_kml();
		printf("direct kernel_sched_timeout(2) returned %ld, trace_call_by_kml() recorded!\n",
		       rc);
	}
	return 0;
}
