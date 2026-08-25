# Linux From Nothing — Arch Host Edition (LFN-Arch)

**Build a bootable, self-hosting, rolling-release Linux system from source**, one package at a time, running it under **QEMU/KVM**.  
No distro, no package manager (until you add one yourself). You compile the kernel, a libc, **zsh**, and every tool by hand until the system can compile *itself*.

Based on **Maple Circuit's "Linux From Nothing" (LFN)** series, heavily reworked for an **Arch Linux host**, modern QEMU/KVM practices, zsh as the primary shell, virtio where it helps, and a more Arch-native "figure it out / rolling" mindset.

Original notes: <https://maplecircuit.dev/lfn/linux-from-nothing.html> · Playlist: <https://www.youtube.com/playlist?list=PLkoRSCZZILDO-YU9Ct-KeVEW71hzeZJu7>

> This is *not* Linux From Scratch. LFN is deliberately looser and more "hit the wall → discover what you need → add it". That is the pedagogical point.

---

## Design goals of this rewrite (Arch edition)

- **Host = Arch Linux** (rolling, pacman, base-devel philosophy).
- **Guest shell = zsh** (not bash). `/bin/sh` → zsh.
- **Rolling by nature**: prefer git clones / latest upstream where sane; fixed tarballs only when a release is required for stability (glibc, gcc, etc.). You keep the system alive by rebuilding what you want from current sources.
- **QEMU/KVM first-class**: virtio block + net recommended, proper `-enable-kvm -cpu host`, bigger default RAM/CPU.
- **Network works out of the box** (Phase 2+) with sensible SLIRP defaults + optional virtio-net.
- **Minimal but usable init** that already does the right mounts + network.
- **Merged /usr** layout from day one (Arch style).
- Extra quality-of-life: better QEMU flags, `sync` discipline, kernel config that includes the syscalls you *will* hit, strace early, etc.

---

## Conventions & mental model

**The core loop (never change this):**

```
mount image  →  build on host (or later inside LFN)  →  install into image  →  sync  →  unmount  →  boot in QEMU  →  test
```

**Two build modes:**
- **Phases 1–3 (cross-build from Arch host):** `make DESTDIR=/mnt install` (or `$LFN`).
- **Phase 4+ (self-hosted / rolling):** build *inside* the running LFN. This is the real milestone.

**Placeholders:**
- `loopN` / `nbd0` → whatever `losetup` / `qemu-nbd` actually prints.
- `$LFN` → absolute path to your root tree (e.g. `/home/you/LFN/root`).
- `-j$(nproc)` → always use your real core count.

**DESTDIR pattern:**  
`make DESTDIR=/mnt install` (or `DESTDIR=$LFN`) installs into the guest tree.  
`--prefix=/usr` tells the software where it will live *at runtime*.

**GRUB trap:** drives start at 0, partitions at 1 → `(hd0,1)` == `/dev/sda1` (or `/dev/vda1` with virtio).

---

## Phase 0 — Arch host preparation

```bash
sudo pacman -Syu --needed \
  base-devel bc binutils bison dwarves flex gcc git gnupg \
  gzip libelf ncurses openssl make perl rsync tar xz \
  autoconf automake libtool gettext gawk bzip2 texinfo \
  qemu-full pahole cpio python zstd elfutils libcap \
  pkgconf which sudo
```

> `qemu-full` pulls in `qemu-system-x86_64`, `qemu-img`, `qemu-nbd`, etc.  
> Make sure your user is in the `kvm` group: `sudo usermod -aG kvm $USER` (then re-login).

Create the project skeleton (merged-/usr, Arch style):

```bash
mkdir -p ~/LFN && cd ~/LFN
mkdir -p root/{boot,proc,sys,dev,etc,var/run,tmp,root,usr/{lib,lib64,bin,sbin,include,share}}
cd root
ln -sf usr/lib   lib
ln -sf usr/lib64 lib64
ln -sf usr/bin   bin
ln -sf usr/sbin  sbin
cd ..

export LFN="$HOME/LFN/root"
```

`proc`, `sys`, `dev` stay empty — kernel + init populate them.

---

## Phase 1 — Kernel + zsh + minimal userland (boot to zsh prompt)

### 1.1 Kernel (minimal + virtio-friendly)

```bash
git clone --depth 1 https://github.com/torvalds/linux
cd linux
make tinyconfig
make menuconfig
```

**Minimum options** (search with `/`):

```
General setup
  [*] Configure standard kernel features (expert users)
    [*] Enable support for printk
    [*] Enable futex support
    [*] Posix Clocks & timers
    [*] Enable eventfd() system call          # you will need this later
  [*] 64-bit kernel

Executable file formats
  [*] Kernel support for ELF binaries
  [*] Kernel support for scripts starting with #!

[*] Enable the block layer

Device Drivers
  [*] PCI support
  Generic Driver Options
    [*] Maintain a devtmpfs filesystem to mount at /dev
    [*] Automount devtmpfs at /dev
  [*] Serial ATA and Parallel ATA drivers (libata)
    [*] AHCI SATA support                     # useful for real disks later
  [*] Virtio drivers                          # highly recommended for QEMU
    [*] PCI driver for virtio devices
    [*] Virtio block driver
    [*] Virtio network driver
  Character devices
    [*] Enable TTY
    Serial drivers
      [*] 8250/16550 and compatible serial support
      [*] Console on 8250/16550 and compatible serial port
  [*] Network device support
    [*] Ethernet driver support
      [*] Intel(R) PRO/1000 Gigabit Ethernet support   # classic e1000
      [*] Virtio network driver

File systems
  [*] The Extended 4 (ext4) filesystem
  Pseudo filesystems
    [*] /proc file system support
    [*] sysfs file system support
    [*] Inotify support for userspace

[*] Networking support
  Networking options
    [*] Packet socket
    [*] Unix domain sockets
    [*] TCP/IP networking
    [*] DNS Resolver support
```

Build & install kernel image:

```bash
make -j$(nproc)
cp arch/x86/boot/bzImage $LFN/boot/
cp .config $LFN/boot/config-$(make -s kernelrelease)
cd ..
```

### 1.2 zsh (the shell)

```bash
git clone --depth 1 https://github.com/zsh-users/zsh
cd zsh
./Util/preconfig          # if configure is missing
./configure --prefix=/usr --enable-multibyte --with-tcsetpgrp
make -j$(nproc)
make DESTDIR=$LFN install
cd ..
ln -sf zsh $LFN/bin/sh    # /bin/sh → zsh
```

> zsh needs ncurses at runtime (we build it next). For a more complete zsh later you can re-build with `--enable-pcre` after pcre2 is available.

### 1.3 Coreutils

```bash
git clone --depth 1 https://github.com/coreutils/coreutils
cd coreutils
./bootstrap               # git only
cd ..
mkdir coreutils-build && cd coreutils-build
../coreutils/configure --without-selinux --disable-libcap --prefix=/usr
make -j$(nproc)
make DESTDIR=$LFN install
cd ..
```

### 1.4 util-linux

```bash
git clone --depth 1 https://github.com/util-linux/util-linux
cd util-linux
./autogen.sh
cd ..
mkdir util-build && cd util-build
../util-linux/configure --disable-liblastlog2 --without-systemd --prefix=/usr
make -j$(nproc)
make DESTDIR=$LFN install
cd ..
```

### 1.5 nano (or micro / neovim later)

```bash
git clone --depth 1 https://git.savannah.gnu.org/git/nano.git
cd nano && ./autogen.sh && cd ..
mkdir nano-build && cd nano-build
../nano/configure --prefix=/usr
make -j$(nproc)
make DESTDIR=$LFN install
cd ..
```

### 1.6 glibc (real release, not pure git)

```bash
# Prefer a recent stable release (check https://ftp.gnu.org/gnu/glibc/)
wget https://ftp.gnu.org/gnu/glibc/glibc-2.41.tar.xz   # or newer
tar -xf glibc-2.41.tar.xz
mkdir glibc-build && cd glibc-build
../glibc-2.41/configure --prefix=/usr --libdir=/lib --without-selinux \
  --enable-kernel=6.1 --disable-werror
make -j$(nproc)
make DESTDIR=$LFN install
cd ..
```

### 1.7 ncurses (wide + non-wide — you will need both)

```bash
wget https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz
tar -xf ncurses-6.5.tar.gz

# Wide (for most programs + zsh)
mkdir ncurses-w-build && cd ncurses-w-build
../ncurses-6.5/configure --with-shared --with-termlib --enable-widec \
  --with-versioned-syms --prefix=/usr
make -j$(nproc)
make DESTDIR=$LFN install
cd ..

# Non-wide (needed later for menuconfig *inside* LFN)
mkdir ncurses-build && cd ncurses-build
../ncurses-6.5/configure --with-shared --with-termlib --disable-widec \
  --with-versioned-syms --prefix=/usr
make -j$(nproc)
make DESTDIR=$LFN install
cd ..

# Symlinks that programs expect
cd $LFN
ln -sf libncursesw.so.6 lib/libncurses.so.6
ln -sf libtinfow.so.6   lib/libtinfo.so.6
cd -
```

Create loader config:

```bash
mkdir -p $LFN/etc
cat > $LFN/etc/ld.so.conf <<EOF
/usr/lib
/usr/lib64
/lib
/lib64
EOF
ldconfig -v -r $LFN
```

### 1.8 init (zsh, with network scaffolding)

```bash
cat > $LFN/sbin/init << 'EOF'
#!/bin/zsh
mount -t proc  none /proc
mount -t sysfs none /sys
mount -t tmpfs none /tmp
mount -t devtmpfs none /dev 2>/dev/null || true

# Basic network for QEMU user-mode (SLIRP)
ip link set eth0 up 2>/dev/null || ip link set ens3 up 2>/dev/null || true
ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || \
  ip addr add 10.0.2.15/24 dev ens3 2>/dev/null || true
ip route add default via 10.0.2.2 2>/dev/null || true

export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export TERM=linux
export HOME=/root

exec /bin/zsh -l
EOF
chmod +x $LFN/sbin/init
```

### 1.9 Disk image (start with qcow2 — better from the beginning)

```bash
qemu-img create -f qcow2 disk.qcow2 20G          # growable, start reasonable
sudo modprobe nbd max_part=16
sudo qemu-nbd -c /dev/nbd0 disk.qcow2
sudo fdisk /dev/nbd0   # n → p → 1 → defaults → a → w
sudo mkfs.ext4 -L LFN /dev/nbd0p1
sudo mount /dev/nbd0p1 /mnt
sudo cp -a $LFN/* /mnt/
```

### 1.10 GRUB

```bash
sudo grub-install --target=i386-pc --root-directory=/mnt \
  --modules="normal part_msdos ext2 multiboot biosdisk" /dev/nbd0

sudo tee /mnt/boot/grub/grub.cfg >/dev/null <<EOF
set timeout=3
set default=0

menuentry 'LFN (zsh)' {
    set root='(hd0,1)'
    linux /boot/bzImage root=/dev/sda1 rw console=ttyS0
}
EOF
```

> With virtio you would use `root=/dev/vda1` and adjust GRUB modules (`virtio_pci virtio_blk`).

### 1.11 First boot

```bash
sync
sudo umount /mnt
sudo qemu-nbd -d /dev/nbd0

qemu-system-x86_64 \
  -enable-kvm -cpu host \
  -m 4G -smp $(nproc) \
  -drive file=disk.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio -nographic
```

✅ You should land in a zsh prompt. Network is not fully usable yet (no DNS, limited tools).

---

## Phase 2 — Network that actually works

Mount again:

```bash
sudo qemu-nbd -c /dev/nbd0 disk.qcow2
sudo mount /dev/nbd0p1 /mnt
```

### 2.1 iproute2 + its libs

Same pattern as original (elfutils, libcap, zlib, zstd). Build on host, `DESTDIR=/mnt`.

After install, rebuild kernel with the networking options already listed in Phase 1 (they should already be on). Re-copy bzImage.

### 2.2 wget + OpenSSL + pcre2

Same as original. Prefer recent releases.

### 2.3 dnsmasq + resolv.conf + passwd

```bash
# inside the mounted tree
echo 'nameserver 1.1.1.1' > /mnt/etc/resolv.conf
echo 'root:x:0:0:root:/root:/bin/zsh' > /mnt/etc/passwd
mkdir -p /mnt/root /mnt/var/run
```

Update `/mnt/sbin/init` to start `dnsmasq -uroot` before the shell.

Test with `wget https://archlinux.org` (or any site) after reboot. Certificate verification will be fixed in Phase 3.

---

## Phase 3 — Self-hosting toolchain (the rolling foundation)

Convert / grow the image if needed, install Linux headers, replace glibc with a clean release if you used git earlier, then:

- GCC (with prerequisites)
- make, binutils, tar, gzip, sed, grep, gawk, …
- CA certificates
- Proper environment variables in init (`COMPILER_PATH`, `LIBRARY_PATH`, `CPATH`, `SSL_CERT_FILE`)

Once GCC + make are inside LFN you can start building **inside the guest**. That is when LFN becomes a true rolling system: you `wget`/`git clone` the latest source of anything and compile it on the target itself.

First self-hosted proof (inside LFN):

```zsh
# on LFN
cd /root
wget https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.gz
# … configure / make / make install  (no DESTDIR)
```

---

## Phase 4 — Git, curl, strace, missing syscalls

Exactly the same learning path as the original series, but with zsh and the Arch-tuned kernel config.  
When something fails with a cryptic error → `strace -o /tmp/t.log <cmd>` → look for `ENOSYS` → enable the missing syscall / feature in the kernel → rebuild kernel *inside* LFN.

You will almost certainly need:

- eventfd / eventfd2
- more POSIX timers / clocks
- keyring / access key retention (for curl)
- etc.

Keep the old kernel as a GRUB fallback.

---

## Phase 5+ — Keep rolling

Python, ninja, meson, git (full), curl, whatever you need.  
Because there is no package manager, the system stays “rolling” only as long as *you* pull newer sources and rebuild. That is the point.

Optional Arch-flavoured improvements you can add later:

- A simple `pkg` helper script that downloads + builds common tarballs.
- `pacman` itself (yes, it is possible, but non-trivial).
- `mkinitcpio`-style initramfs if you ever want real hardware.
- `systemd` (or OpenRC / s6) if you outgrow the hand-written init.
- Virtio-fs or 9p for sharing host directories into the guest during development.

---

## Quick reference (Arch + QEMU/KVM)

**Mount qcow2:**
```bash
sudo modprobe nbd max_part=16
sudo qemu-nbd -c /dev/nbd0 disk.qcow2
sudo mount /dev/nbd0p1 /mnt
```

**Unmount:**
```bash
sync
sudo umount /mnt
sudo qemu-nbd -d /dev/nbd0
```

**Full-power boot (recommended):**
```bash
qemu-system-x86_64 \
  -enable-kvm -cpu host \
  -m 8G -smp $(nproc) \
  -drive file=disk.qcow2,format=qcow2,if=virtio,cache=writeback \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio -nographic
```

**menuconfig navigation:** arrows, Enter, Space, `/` search, Esc Esc, save on exit.

---

## Recurring gotchas (Arch edition)

- Always use the real device names printed by `losetup` / `qemu-nbd`.
- GRUB `(hd0,1)` vs kernel `/dev/sda1` (or `/dev/vda1` with virtio).
- QEMU user-mode networking does **not** pass ICMP reliably — never debug with `ping`.
- `DESTDIR=/mnt` = cross; no DESTDIR = live install inside LFN.
- `autoconf` often hates `-j`.
- Keep both wide and non-wide ncurses.
- `sync` three times before every unmount / reboot.
- When a program fails cryptically → `strace` → `ENOSYS` → kernel config.

---

## Credit & philosophy

All original methodology and discovery process belong to **Maple Circuit**.  
This rewrite simply makes the host Arch-native, the shell zsh, the networking/virtio more modern, and the whole thing more “rolling / Arch brain”.

Build it, break it, fix it, understand *why* each piece exists. That is the only goal.

---

*Last updated for Arch hosts + QEMU/KVM, July 2026.*
