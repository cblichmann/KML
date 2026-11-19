# SPDX-License-Identifier: GPL-2.0-only

.PHONY: all kernel initramfs test run clean

all: kernel initramfs

kernel:
	./build-kernel.sh

initramfs:
	./build-initramfs.sh

test: initramfs
	./run-qemu.sh --test

run: initramfs
	./run-qemu.sh

clean:
	rm -rf out
