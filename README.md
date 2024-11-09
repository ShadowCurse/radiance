# Radiance

Experimental KVM based VMM for aarch64 platform.

Defining characteristics:
- no external dependencies
- statically compiled (no libc or musl)
- no memory allocations after the VM start
- minimal memory overhead over requested VM memory size

Build:
```bash
    $ zig build -Doptimize=ReleaseFast -j4
```

Usage:
```bash
Usage:
        --config_path: type []const u8
```

Example:
```bash
radiance --config_path config.toml
```

Example config file:
```toml
[machine]
vcpus = 2
memory_mb = 128

[kernel]
path = "vmlinux-5.10"

[[drives]]
read_only = true
path = "ubuntu-22.04.ext4"

```

Linux kernel:
To compile kernel use:
```bash
make -Image -j
```
The resulting kernel image will be at `arch/arm64/boot/Image`.

Kcov:
```bash
zig test src/main.zig -lc --test-cmd kcov --test-cmd "--exclude-pattern=/nix" --test-cmd kcov-output --test-cmd-bin

```
