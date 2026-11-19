// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal Kernel Mode Linux (KML) example program.
 *
 * When executed from /trusted/hello_kml, this program runs in CPU Ring 0
 * (CPL=0) and invokes kernel functions directly through the KML vDSO without
 * software interrupts or privilege-level context switches.
 */

#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

extern signed long kernel_sched_timeout(signed long timeout);
extern long trace_call_by_kml(void);

int main(void)
{
	uint16_t cs;
	struct timespec ts;

	__asm__ volatile("mov %%cs, %0" : "=r"(cs));
	printf("hello_kml (pid=%d): CS=0x%04x, CPL=%d (%s)\n",
	       getpid(), cs, cs & 3,
	       ((cs & 3) == 0) ? "Kernel Mode / Ring 0" : "User Mode / Ring 3");

	clock_gettime(CLOCK_MONOTONIC, &ts);
	printf("monotonic time via vDSO: %lld.%09ld s\n",
	       (long long)ts.tv_sec, ts.tv_nsec);

	if ((cs & 3) == 0) {
		long rc = kernel_sched_timeout(2);

		trace_call_by_kml();
		printf("direct kernel_sched_timeout(2) returned %ld, trace_call_by_kml() recorded!\n",
		       rc);
	}
	return 0;
}
