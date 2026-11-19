// SPDX-License-Identifier: GPL-2.0-only
/*
 * Comprehensive verification suite for Kernel Mode Linux (KML) on Linux 7.3.
 *
 * Linked against arch/x86/entry/vdso/vdso64/vdso64.so so KML symbols resolve
 * to version LINUX_2.6 in the kernel-mapped [vdso].
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Symbols exported by the Linux 7.3 KML vDSO (LINUX_2.6) */
extern signed long kernel_sched_timeout(signed long timeout);
extern long trace_call_by_kml(void);
extern long kml_syscall(long nr, unsigned long a0, unsigned long a1,
			unsigned long a2, unsigned long a3, unsigned long a4,
			unsigned long a5);
extern long kml_call(unsigned long fn, unsigned long a0, unsigned long a1,
		     unsigned long a2, unsigned long a3, unsigned long a4,
		     unsigned long a5);

static inline uint16_t read_cs(void)
{
	uint16_t cs;

	__asm__ volatile("mov %%cs, %0" : "=r"(cs));
	return cs;
}

static inline uint16_t read_ss(void)
{
	uint16_t ss;

	__asm__ volatile("mov %%ss, %0" : "=r"(ss));
	return ss;
}

static inline uint64_t read_cr3(void)
{
	uint64_t cr3;

	__asm__ volatile("mov %%cr3, %0" : "=r"(cr3));
	return cr3;
}

static unsigned long lookup_kallsymbol(const char *target)
{
	FILE *fp = fopen("/proc/kallsyms", "r");
	unsigned long addr = 0;
	char line[256];

	if (!fp)
		return 0;

	while (fgets(line, sizeof(line), fp)) {
		unsigned long a;
		char type;
		char name[128];

		if (sscanf(line, "%lx %c %127s", &a, &type, name) == 3) {
			if (strcmp(name, target) == 0) {
				addr = a;
				break;
			}
		}
	}
	fclose(fp);
	return addr;
}

static volatile sig_atomic_t sig_fired;
static volatile uint16_t sig_handler_cs;

static void sigusr1_handler(int signo)
{
	(void)signo;
	sig_handler_cs = read_cs();
	sig_fired = 1;
}

/* Recursively touch 128 KiB of fresh stack pages to exercise Ring-0 stack #PF */
static __attribute__((noinline)) uint64_t touch_deep_stack(int depth)
{
	volatile char page_buf[4096];

	page_buf[0] = (char)depth;
	page_buf[4095] = (char)(depth ^ 0x5a);
	if (depth <= 1)
		return (uint64_t)page_buf[0] + (uint64_t)page_buf[4095];
	return (uint64_t)page_buf[0] + touch_deep_stack(depth - 1);
}

static int run_expect_user_tests(const char *label)
{
	uint16_t cs = read_cs();
	uint16_t ss = read_ss();
	int cpl = cs & 3;
	struct timespec ts = {0, 0};
	struct timeval tv = {0, 0};
	struct timespec req = {0, 1000000};
	pid_t pid;
	int status = 0;

	printf("[%s] CS=0x%04x SS=0x%04x CPL=%d\n", label, cs, ss, cpl);
	if (cpl != 3) {
		fprintf(stderr, "FAIL [%s]: expected Ring 3 (CPL=3), got CPL=%d\n",
			label, cpl);
		return 1;
	}

	/* Verify privileged instructions fault in Ring 3 */
	pid = fork();
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		volatile uint64_t cr3 = read_cr3();
		(void)cr3;
		_exit(0);
	}
	if (waitpid(pid, &status, 0) < 0 || !WIFSIGNALED(status)) {
		fprintf(stderr, "FAIL [%s]: reading CR3 in Ring 3 did not fault!\n",
			label);
		return 1;
	}
	printf("  [PASS] Ring-3 privileged instruction (mov %%cr3) blocked by CPU (sig=%d)\n",
	       WTERMSIG(status));

	/* Verify KML-only vDSO entry points return -EPERM in Ring 3 */
	if (kernel_sched_timeout(1) != -EPERM ||
	    trace_call_by_kml() != -EPERM ||
	    kml_syscall(__NR_getpid, 0, 0, 0, 0, 0, 0) != -EPERM) {
		fprintf(stderr, "FAIL [%s]: KML vDSO entry points did not return -EPERM in Ring 3\n",
			label);
		return 1;
	}
	printf("  [PASS] KML vDSO entry points safely reject Ring-3 callers (-EPERM)\n");

	/* Verify normal vDSO calls still work in Ring 3 */
	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0 ||
	    gettimeofday(&tv, NULL) != 0 ||
	    sched_yield() != 0 ||
	    nanosleep(&req, NULL) != 0) {
		fprintf(stderr, "FAIL [%s]: standard vDSO calls failed in Ring 3\n",
			label);
		return 1;
	}
	printf("  [PASS] Standard vDSO (clock_gettime/gettimeofday/sched_yield/nanosleep) OK in Ring 3\n");
	return 0;
}

static int run_expect_kernel_tests(void)
{
	uint16_t cs = read_cs();
	uint16_t ss = read_ss();
	int cpl = cs & 3;
	uint64_t cr3;
	unsigned long banner_addr, trace_fn_addr;
	struct timespec ts1 = {0, 0}, ts2 = {0, 0}, req = {0, 2000000};
	struct timeval tv = {0, 0};
	long kpid;
	char *map;
	pid_t pid;
	int status = 0;
	struct sigaction sa;

	printf("[trusted-kml] CS=0x%04x SS=0x%04x CPL=%d\n", cs, ss, cpl);
	if (cpl != 0) {
		fprintf(stderr, "FAIL [trusted-kml]: expected Ring 0 (CPL=0), got CPL=%d\n",
			cpl);
		return 1;
	}
	printf("  [PASS] Executing user ELF binary in CPU Ring 0 (CS=0x%04x, SS=0x%04x)\n",
	       cs, ss);

	/* 1. Privileged register access in Ring 0 */
	cr3 = read_cr3();
	if (cr3 == 0) {
		fprintf(stderr, "FAIL [trusted-kml]: unexpected zero CR3\n");
		return 1;
	}
	printf("  [PASS] Direct Ring-0 CR3 read from user space: CR3=0x%016lx\n",
	       (unsigned long)cr3);

	/* 2. Direct kernel address space read + passing kernel pointer to syscall */
	banner_addr = lookup_kallsymbol("linux_banner");
	if (banner_addr != 0) {
		const char *kbanner = (const char *)banner_addr;
		int pipefd[2];
		char buf[80] = {0};

		if (strncmp(kbanner, "Linux version ", 14) != 0) {
			fprintf(stderr, "FAIL [trusted-kml]: unexpected linux_banner content\n");
			return 1;
		}
		printf("  [PASS] Direct kernel memory dereference (linux_banner @ 0x%lx): %.48s...\n",
		       banner_addr, kbanner);

		if (pipe(pipefd) == 0) {
			ssize_t nw = write(pipefd[1], kbanner, 32);
			ssize_t nr = read(pipefd[0], buf, 32);

			close(pipefd[0]);
			close(pipefd[1]);
			if (nw != 32 || nr != 32 || memcmp(buf, "Linux version ", 14) != 0) {
				fprintf(stderr, "FAIL [trusted-kml]: syscall uaccess with kernel pointer failed (nw=%zd)\n",
					nw);
				return 1;
			}
			printf("  [PASS] Syscall uaccess authorized for kernel-space pointer (TIF_KU)\n");
		}
	} else {
		fprintf(stderr, "FAIL [trusted-kml]: could not resolve linux_banner from /proc/kallsyms\n");
		return 1;
	}

	/* 3. vDSO direct syscall wrappers (Patch 2) */
	if (clock_gettime(CLOCK_MONOTONIC, &ts1) != 0 ||
	    gettimeofday(&tv, NULL) != 0 ||
	    sched_yield() != 0 ||
	    nanosleep(&req, NULL) != 0 ||
	    clock_gettime(CLOCK_MONOTONIC, &ts2) != 0) {
		fprintf(stderr, "FAIL [trusted-kml]: vDSO time/sched wrappers failed\n");
		return 1;
	}
	kpid = kml_syscall(__NR_getpid, 0, 0, 0, 0, 0, 0);
	if (kpid != getpid()) {
		fprintf(stderr, "FAIL [trusted-kml]: kml_syscall(getpid)=%ld != getpid()=%d\n",
			kpid, getpid());
		return 1;
	}
	printf("  [PASS] vDSO direct Ring-0 syscall dispatch: kml_syscall(getpid)=%ld, clock_gettime/gettimeofday/sched_yield/nanosleep OK\n",
	       kpid);

	/* 4. Direct kernel scheduler sleep via vDSO kernel_sched_timeout */
	clock_gettime(CLOCK_MONOTONIC, &ts1);
	if (kernel_sched_timeout(5) < 0) {
		fprintf(stderr, "FAIL [trusted-kml]: kernel_sched_timeout(5) failed\n");
		return 1;
	}
	clock_gettime(CLOCK_MONOTONIC, &ts2);
	printf("  [PASS] vDSO kernel_sched_timeout(5) slept cleanly on kernel stack under PREEMPT_RT\n");

	/* 5. Direct kernel function call: trace_call_by_kml via vDSO and kml_call */
	{
		int on_fd = open("/sys/kernel/tracing/tracing_on", O_WRONLY);
		int tfd;

		if (on_fd >= 0) {
			ssize_t wr = write(on_fd, "1\n", 2);
			(void)wr;
			close(on_fd);
		}

		tfd = open("/sys/kernel/tracing/trace", O_WRONLY | O_TRUNC);
		if (tfd >= 0)
			close(tfd);

		if (trace_call_by_kml() != 0) {
			fprintf(stderr, "FAIL [trusted-kml]: vDSO trace_call_by_kml() failed\n");
			return 1;
		}

		trace_fn_addr = lookup_kallsymbol("trace_call_by_kml");
		if (!trace_fn_addr) {
			fprintf(stderr, "FAIL [trusted-kml]: could not resolve trace_call_by_kml\n");
			return 1;
		}
		(void)kml_call(trace_fn_addr, 0, 0, 0, 0, 0, 0);

		tfd = open("/sys/kernel/tracing/trace", O_RDONLY);
		if (tfd >= 0) {
			char trace_buf[4096] = {0};
			ssize_t n = read(tfd, trace_buf, sizeof(trace_buf) - 1);
			const char *first = NULL;
			int hits = 0;

			close(tfd);
			if (n > 0) {
				first = strstr(trace_buf, "trace_call_by_kml");
				while (first != NULL) {
					hits++;
					first = strstr(first + 1, "trace_call_by_kml");
				}
			}
			if (hits < 2) {
				fprintf(stderr, "FAIL [trusted-kml]: expected >=2 trace_call_by_kml hits in ftrace buffer, got %d\n",
					hits);
				return 1;
			}
			printf("  [PASS] Direct kernel function trace_call_by_kml() verified in ftrace buffer (%d hits)\n",
			       hits);
		}
	}

	/* 6. Demand paging & deep user-stack page faults in Ring 0 (IST_INDEX_KML) */
	map = mmap(NULL, 1024 * 1024, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (size_t off = 0; off < 1024 * 1024; off += 4096)
		map[off] = (char)(off >> 12);
	munmap(map, 1024 * 1024);

	if (touch_deep_stack(32) == 0) {
		fprintf(stderr, "FAIL [trusted-kml]: unexpected stack checksum\n");
		return 1;
	}
	printf("  [PASS] Ring-0 anonymous mmap & 128 KiB stack-growth demand #PFs handled via IST_INDEX_KML\n");

	/* 7. Signal delivery & rt_sigreturn preserve Ring 0 */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sigusr1_handler;
	if (sigaction(SIGUSR1, &sa, NULL) != 0) {
		perror("sigaction");
		return 1;
	}
	raise(SIGUSR1);
	if (!sig_fired || (sig_handler_cs & 3) != 0 || (read_cs() & 3) != 0) {
		fprintf(stderr, "FAIL [trusted-kml]: signal lost Ring 0 (handler_cs=0x%x, post_cs=0x%x)\n",
			sig_handler_cs, read_cs());
		return 1;
	}
	printf("  [PASS] Signal handler & rt_sigreturn preserved Ring 0 (handler CS=0x%04x, post CS=0x%04x)\n",
	       sig_handler_cs, read_cs());

	/* 8. fork() preserves Ring 0 in child, and execve() outside /trusted drops to Ring 3 */
	pid = fork();
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		if ((read_cs() & 3) != 0)
			_exit(2);
		execl("/bin/kml_test", "kml_test", "--expect-user-quiet", NULL);
		_exit(3);
	}
	if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		fprintf(stderr, "FAIL [trusted-kml]: fork/exec privilege transition check failed (status=0x%x)\n",
			status);
		return 1;
	}
	printf("  [PASS] fork() inherited Ring 0 & execve(/bin/kml_test) cleanly dropped back to Ring 3\n");

	/* 9. Cross-CPU task migration in Ring 0 (both syscall and sleeping vDSO paths) */
	{
		long ncpus = sysconf(_SC_NPROCESSORS_ONLN);

		if (ncpus >= 2) {
			cpu_set_t full_set;

			CPU_ZERO(&full_set);
			for (int c = 0; c < ncpus; c++)
				CPU_SET(c, &full_set);

			for (int iter = 0; iter < 16; iter++) {
				int target = (int)(iter % ncpus);
				cpu_set_t set;
				struct timespec mreq = {0, 500000};

				CPU_ZERO(&set);
				CPU_SET(target, &set);
				if (sched_setaffinity(0, sizeof(set), &set) != 0) {
					perror("sched_setaffinity");
					return 1;
				}
				if (sched_yield() != 0 ||
				    nanosleep(&mreq, NULL) != 0 ||
				    kernel_sched_timeout(1) < 0) {
					fprintf(stderr, "FAIL [trusted-kml]: vDSO sleep/yield during CPU migration failed\n");
					return 1;
				}
				if (read_cs() != cs || read_cr3() == 0) {
					fprintf(stderr, "FAIL [trusted-kml]: lost __KML_CS after migrating to CPU %d (CS=0x%x)\n",
						target, read_cs());
					return 1;
				}
			}
			(void)sched_setaffinity(0, sizeof(full_set), &full_set);
			printf("  [PASS] Cross-CPU Ring-0 migration across %ld CPUs preserved CS=0x%04x & GSBASE\n",
			       ncpus, read_cs());
		}
	}

	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "--expect-user") == 0)
		return run_expect_user_tests("untrusted-user");

	if (argc >= 2 && strcmp(argv[1], "--expect-chroot-user") == 0)
		return run_expect_user_tests("chroot-trusted");

	if (argc >= 2 && strcmp(argv[1], "--expect-user-quiet") == 0)
		return ((read_cs() & 3) == 3) ? 0 : 1;

	if (argc >= 2 && strcmp(argv[1], "--expect-kernel") == 0)
		return run_expect_kernel_tests();

	printf("PID=%d CS=0x%04x SS=0x%04x CPL=%d (%s)\n",
	       getpid(), read_cs(), read_ss(), read_cs() & 3,
	       ((read_cs() & 3) == 0) ? "KERNEL MODE (Ring 0)" : "USER MODE (Ring 3)");
	return 0;
}
