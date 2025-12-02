# Radiance

Experimental KVM based VMM for `aarch64` platform.

> [!NOTE]
>
> Currently only systems with `GICv2`/`m` like Raspberry Pi 4/5 are supported since this
> is the only `aarch64` hardware I have for development.

Defining characteristics:
- no external dependencies
- statically compiled (no libc or musl)
- no memory allocations after the VM start
- minimal memory overhead over requested VM memory size
- support for Block,Net,Pmem,Uart,Rtc devices
- support for PCI (currently only for Block)
- optimized MMIO device path which makes MMIO devices as fast as PCI ones
- snapshot creation/restoration

### Build:
```bash
zig build -Doptimize=ReleaseFast
```

### Usage:
```bash
Usage:
        --config-path
```

#### Example:

Start VM from config
```bash
radiance --config-path config.toml
```

Pause/Snapshot/Resume
```bash
echo "pause" | sudo socat - UNIX-CONNECT:./test.socket
echo "snapshot snap.rad" | sudo socat - UNIX-CONNECT:./test.socket
echo "resume" | sudo socat - UNIX-CONNECT:./test.socket
```

Restore VM from snapshot
```bash
radiance --snapshot-path ./snap.rad
```

### Example config file:
```toml
[machine]
vcpus = 2
memory_mb = 128
cmdline = "reboot=k panic=1"

[api]
socket_path = "./test.socket"

[uart]
enabled = true

[kernel]
path = "path_to_kernel"

[[drives]]
path = "path_to_rootfs"
read_only = true
rootfs = true
pci = true

[[networks]]
dev_name = "tap0"
mac = [AA, BB, CC, DD, EE, FF]

[[pmems]]
path = "some_file"

```

### Rootfs:

> [!NOTE]
>
> Generated ssh keys will be owned by root user. To use them with `ssh`
> change ownership with `chown`.

#### Ubuntu:
```bash
sudo bash mk_ubuntu.sh 300
```
This will produce `ubuntu.ext4` rootfs file and
ssh keys `ubuntu.id_rsa` and `ubuntu.id_rsa.pub`.

#### Alpine:
```bash
sudo bash mk_alpine.sh 100
```
This will produce `alpine.ext4` rootfs file and
ssh keys `alpine.id_rsa` and `alpine.id_rsa.pub`.

### Linux kernel:
To compile small kernel for VM use `resources/kernel_config`.
```bash
make -Image -j
```
The resulting kernel image will be at `arch/arm64/boot/Image`.

Kcov:
```bash
zig test src/main.zig -lc --test-cmd kcov --test-cmd "--exclude-pattern=/nix" --test-cmd kcov-output --test-cmd-bin

```
