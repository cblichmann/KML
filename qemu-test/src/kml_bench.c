// SPDX-License-Identifier: GPL-2.0-only
/*
 * Syscall vs KML direct kernel call microbenchmark.
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

extern long kml_syscall(long nr, unsigned long a0, unsigned long a1,
			unsigned long a2, unsigned long a3, unsigned long a4,
			unsigned long a5);

static inline uint16_t read_cs(void)
{
	uint16_t cs;

	__asm__ volatile("mov %%cs, %0" : "=r"(cs));
	return cs;
}

static inline uint64_t now_ns(void)
{
	struct timespec ts;

	syscall(__NR_clock_gettime, CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline long raw_syscall0(long nr)
{
	long ret;

	__asm__ volatile("syscall"
			 : "=a"(ret)
			 : "0"(nr)
			 : "rcx", "r11", "memory");
	return ret;
}

int main(int argc, char **argv)
{
	long iters = (argc >= 2) ? atol(argv[1]) : 200000;
	uint16_t cs = read_cs();
	int cpl = cs & 3;
	uint64_t t0, t1;
	volatile long sink = 0;

	printf("[kml_bench] CPL=%d (%s), iterations=%ld\n",
	       cpl, (cpl == 0) ? "Ring 0 KML" : "Ring 3 User", iters);

	/* Warmup */
	for (long i = 0; i < 1000; i++)
		sink += raw_syscall0(__NR_getpid);

	t0 = now_ns();
	for (long i = 0; i < iters; i++)
		sink += raw_syscall0(__NR_getpid);
	t1 = now_ns();
	printf("  syscall instruction (getpid):      %7.1f ns/call\n",
	       (double)(t1 - t0) / (double)iters);

	if (cpl == 0) {
		for (long i = 0; i < 1000; i++)
			sink += kml_syscall(__NR_getpid, 0, 0, 0, 0, 0, 0);

		t0 = now_ns();
		for (long i = 0; i < iters; i++)
			sink += kml_syscall(__NR_getpid, 0, 0, 0, 0, 0, 0);
		t1 = now_ns();
		printf("  KML vDSO direct call (getpid):     %7.1f ns/call\n",
		       (double)(t1 - t0) / (double)iters);
	}

	(void)sink;
	return 0;
}
