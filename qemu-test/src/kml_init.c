// SPDX-License-Identifier: GPL-2.0-only
/*
 * Self-contained PID 1 init for KML QEMU initramfs when a target-architecture
 * busybox binary is not installed on a cross-compilation host.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static int run_cmd(const char *chroot_dir, char *const argv[])
{
	int status = 0;
	pid_t pid = fork();

	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		if (chroot_dir) {
			if (chroot(chroot_dir) != 0 || chdir("/") != 0) {
				perror("chroot");
				_exit(127);
			}
		}
		execv(argv[0], argv);
		perror(argv[0]);
		_exit(127);
	}
	if (waitpid(pid, &status, 0) < 0)
		return 1;
	if (!WIFEXITED(status))
		return 1;
	return WEXITSTATUS(status);
}

static void mount_early_fs(void)
{
	(void)mount("proc", "/proc", "proc", 0, NULL);
	(void)mount("sysfs", "/sys", "sysfs", 0, NULL);
	(void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	(void)mkdir("/dev/pts", 0755);
	(void)mkdir("/dev/shm", 01777);
	(void)mkdir("/sys/kernel/debug", 0755);
	(void)mkdir("/sys/kernel/tracing", 0755);
	(void)mount("tmpfs", "/tmp", "tmpfs", 0, NULL);
	(void)mount("tmpfs", "/dev/shm", "tmpfs", 0, NULL);
	(void)mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);
	(void)mount("tracefs", "/sys/kernel/tracing", "tracefs", 0, NULL);
}

static int cmdline_has_selftest(void)
{
	char buf[1024] = {0};
	int fd = open("/proc/cmdline", O_RDONLY);

	if (fd < 0)
		return 0;
	if (read(fd, buf, sizeof(buf) - 1) <= 0) {
		close(fd);
		return 0;
	}
	close(fd);
	return strstr(buf, "kml.selftest=1") != NULL;
}

static void builtin_ls(const char *path)
{
	DIR *d = opendir(path ? path : ".");
	struct dirent *de;

	if (!d) {
		perror(path ? path : ".");
		return;
	}
	while ((de = readdir(d)) != NULL) {
		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;
		printf("%s  ", de->d_name);
	}
	printf("\n");
	closedir(d);
}

static void builtin_cat(const char *path)
{
	char buf[1024];
	ssize_t n;
	int fd;

	if (!path)
		return;
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return;
	}
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		(void)write(STDOUT_FILENO, buf, (size_t)n);
	close(fd);
}

static void interactive_shell(void)
{
	char line[512];

	printf("\nInteractive KML shell ready. Useful commands:\n");
	printf("  /trusted/hello_kml      # Run minimal demo in Kernel Mode\n");
	printf("  /bin/kml_test           # Show mode in User Mode\n");
	printf("  /trusted/kml_test       # Show mode in Kernel Mode\n");
	printf("  /trusted/kml_test --expect-kernel\n");
	printf("  /trusted/kml_bench 200000\n");
	printf("  poweroff                # Exit QEMU cleanly\n\n");

	for (;;) {
		char *argv[32];
		int argc = 0;
		char *tok;

		printf("kml-sh# ");
		fflush(stdout);
		if (!fgets(line, sizeof(line), stdin))
			break;

		tok = strtok(line, " \t\r\n");
		while (tok && argc < 31) {
			argv[argc++] = tok;
			tok = strtok(NULL, " \t\r\n");
		}
		argv[argc] = NULL;
		if (argc == 0)
			continue;

		if (strcmp(argv[0], "poweroff") == 0 || strcmp(argv[0], "exit") == 0) {
			sync();
			(void)reboot(RB_POWER_OFF);
			return;
		}
		if (strcmp(argv[0], "cd") == 0) {
			if (chdir(argc > 1 ? argv[1] : "/") != 0)
				perror("cd");
			continue;
		}
		if (strcmp(argv[0], "ls") == 0) {
			builtin_ls(argc > 1 ? argv[1] : ".");
			continue;
		}
		if (strcmp(argv[0], "cat") == 0) {
			for (int i = 1; i < argc; i++)
				builtin_cat(argv[i]);
			continue;
		}
		if (strcmp(argv[0], "chroot") == 0 && argc >= 3) {
			(void)run_cmd(argv[1], &argv[2]);
			continue;
		}
		(void)run_cmd(NULL, argv);
	}
}

int main(void)
{
	struct utsname uts;

	setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
	mount_early_fs();

	memset(&uts, 0, sizeof(uts));
	(void)uname(&uts);

	printf("\n================================================================\n");
	printf(" Kernel Mode Linux (KML) Test Environment\n");
	printf(" Kernel: %s %s %s %s\n",
	       uts.sysname, uts.release, uts.version, uts.machine);
	printf("================================================================\n");
	fflush(stdout);

	if (cmdline_has_selftest()) {
		int fail = 0;
		char *const c1[] = {"/bin/kml_test", "--expect-user", NULL};
		char *const c2[] = {"/trusted/kml_test", "--expect-chroot-user", NULL};
		char *const c3[] = {"/trusted/kml_test", "--expect-kernel", NULL};
		char *const c4[] = {"/trusted/hello_kml", NULL};
		char *const c5a[] = {"/bin/kml_bench", "100000", NULL};
		char *const c5b[] = {"/trusted/kml_bench", "100000", NULL};

		printf("[*] Running automated KML verification suite...\n");

		printf("\n--- [1/5] Untrusted binary (/bin/kml_test -> expect unprivileged user mode) ---\n");
		fflush(stdout);
		if (run_cmd(NULL, c1) != 0)
			fail = 1;

		printf("\n--- [2/5] Chrooted /trusted binary (CONFIG_KML_CHECK_CHROOT -> expect user mode) ---\n");
		fflush(stdout);
		if (run_cmd("/chroot_jail", c2) != 0)
			fail = 1;

		printf("\n--- [3/5] Trusted KML binary (/trusted/kml_test -> expect kernel mode) ---\n");
		fflush(stdout);
		if (run_cmd(NULL, c3) != 0)
			fail = 1;

		printf("\n--- [4/5] Minimal KML tutorial binary (/trusted/hello_kml) ---\n");
		fflush(stdout);
		if (run_cmd(NULL, c4) != 0)
			fail = 1;

		printf("\n--- [5/5] Syscall vs KML vDSO Direct Call Microbenchmark ---\n");
		fflush(stdout);
		if (run_cmd(NULL, c5a) != 0)
			fail = 1;
		if (run_cmd(NULL, c5b) != 0)
			fail = 1;

		printf("\n");
		if (fail == 0)
			printf("=== ALL KML TESTS PASSED ===\n");
		else
			printf("=== KML TEST SUITE FAILED ===\n");
		fflush(stdout);

		sync();
		(void)reboot(RB_POWER_OFF);
		return fail;
	}

	if (access("/bin/busybox", X_OK) == 0) {
		char *const sh_argv[] = {"/bin/busybox", "sh", NULL};

		execv("/bin/busybox", sh_argv);
	}

	interactive_shell();
	sync();
	(void)reboot(RB_POWER_OFF);
	return 0;
}
