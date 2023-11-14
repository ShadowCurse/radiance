# Radiance

Experimental KVM based VMM for aarch64 platform.

Build:
```bash
    $ zig build -Doptimize=ReleaseFast -j4
```

Usage:
```bash
Usage:
        --kernel_path: type []const u8
        --rootfs_path: type []const u8
        --memory_size: type u32
```

Example:
```bash
radiance --kernel_path vmlinux-5.10.186 --rootfs_path ubuntu-22.04.ext4 --memory_size 128
```

Linux kernel:
To compile kernel use:
```bash
make -Image -j
```
The resulting kernel image will be at `arch/arm64/boot/Image`.
