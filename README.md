# Linux From Something
> ## Arch Host Edition!
>
> ***Watch on Asciinema.org***
> [![asciicast](https://asciinema.org/a/1265310.svg)](https://asciinema.org/a/1265310)
 
A working implementation of [`LFN-2.md`](LFN-2.md): a bootable, self-hosting
Linux system built from source, one package at a time, running under
QEMU/KVM. No distribution, no package manager. The kernel, the C library,
zsh and every tool are compiled here; by Phase 3 the system can compile
itself.

```
./lfn build          # build everything that is not already done
./lfn boot           # boot it and get a zsh prompt
./lfn test           # boot it unattended and assert that it works
```

---

## What this actually is

`LFN-2.md` is a set of instructions for a human sitting at a terminal:
run `make menuconfig`, click these options, `sudo mount` the image, copy
files in, boot, see what breaks. This repository turns that into something
that runs unattended and can be repeated: 24 build stages, each idempotent,
each verified, plus a boot-test harness that drives the guest's serial
console and checks the answers.

The pedagogy of LFN is preserved. Nothing is hidden behind a package
manager, every package is configured and compiled explicitly, and when
something is switched off there is a comment saying why.

## Layout

```
lfn                     the build driver
lfn.conf                versions, paths, kernel symbol list — the one file to edit
scripts/stages/*.sh     one stage per package or milestone, run in numeric order
scripts/lib/            shared helpers, and the expect harness for boot tests
scripts/boot.sh         interactive QEMU launcher
scripts/test.sh         automated boot tests
tests/*.expect          what "it works" means, as assertions
work/                   everything big and regenerable (not in git):
  sources/  src/  build/  root/  out/  logs/  stamps/
```

`work/root` is the guest filesystem tree — the `$LFN` of the doc.
`work/out/rootfs.ext4` and `work/out/disk.img` are the bootable results.

## Host requirements

Arch, and the packages the doc lists:

```bash
sudo pacman -Syu --needed base-devel bc binutils bison flex gcc git gzip \
  libelf ncurses openssl make perl rsync tar xz autoconf automake libtool \
  gettext gawk bzip2 qemu-full cpio python zstd elfutils libcap pkgconf \
  fakeroot e2fsprogs
```

`./lfn build 00-host-check` verifies all of it and refuses to continue if
something essential is missing.

## The one deliberate deviation: no root

The doc mounts the guest image with `modprobe nbd`, `qemu-nbd` and `mount`,
all of which need root. This build never asks for a password. Two
substitutions make that work, and they are strictly better for a repeatable
build:

| doc | here | why |
|---|---|---|
| `qemu-nbd` + `mount` + `cp -a` | `mke2fs -d $LFN image` | builds the filesystem straight from a directory |
| `make install` as root | `fakeroot make install` | records root:root ownership without being root |
| `grub-install /dev/nbd0` | `grub-mkimage` + `grub-bios-setup` on the image file | GRUB's own tools work fine on a plain file |
| `ldconfig -r $LFN` | `ldconfig` on first boot, from init | `-r` chroots, which fakeroot cannot fake |

The result is identical: a partitioned disk with a real MBR, a real GRUB in
the boot sector, and a root-owned filesystem.

There is also a faster path used during development — `./lfn boot` hands the
kernel to QEMU directly with `-kernel`, skipping the bootloader entirely.
Both work; `./lfn boot --disk` is the one that proves the disk would boot
real hardware.

## The phases

| stage | phase | what lands in the guest |
|---|---|---|
| `00`, `05` | 0 | host check, merged-`/usr` skeleton |
| `10` | 1.1a | kernel source + userspace headers |
| `15` | 1.6 | glibc |
| `20` | 1.7 | ncurses, wide and non-wide |
| `25` | 1.2 | zsh — `/bin/sh` points at it |
| `30`, `35`, `40` | 1.3–1.5 | coreutils, util-linux, nano |
| `45` | 1.8 | `/etc` and init |
| `50` | 1.1b | the kernel image |
| `60`–`68` | 2 | zlib/libmnl/libcap, iproute2, OpenSSL + CA roots, pcre2, wget, dnsmasq |
| `70`–`75` | 3 | binutils, GCC, make/sed/grep/awk/tar/perl/… |
| `80`–`82` | 4 | curl, git, strace |
| `90`, `92` | 5 | GRUB from source, bootable partitioned disk |
| `99` | — | the plain root filesystem image |

Phase 3 is the milestone that matters: once GCC and make are inside the
guest, LFN builds its own software, on itself, from upstream tarballs. Test
`03-selfhost` proves it by compiling a program inside the VM.

## Using it

```bash
./lfn list                 # every stage and whether it is done
./lfn build                # run everything still pending
./lfn build 72-gcc         # or just one — by number, by name, or by both
./lfn redo 50-kernel       # forget a stage and do it again
./lfn status               # tree size, kernel, images, free space
./lfn check                # every installed binary's dependencies resolve?

./lfn boot                 # interactive, direct kernel boot
./lfn boot --disk          # through GRUB, like real hardware
./lfn boot --rescue        # init=/bin/zsh, when init itself is broken
./lfn boot --debug         # earlyprintk, when the kernel dies before init

./lfn test                 # all boot tests
./lfn test 01-boot --echo  # one test, with the guest's output on screen
```

Leave the guest with `poweroff`, or `Ctrl-A X`.

Stage logs are in `work/logs/`. Every stage is resumable: interrupt the
build, run it again, and it picks up at the first unstamped stage.

### Changing what gets built

`lfn.conf` holds every version number, the QEMU sizing, and the kernel
symbol list. Bumping a package is one edit plus `./lfn redo <stage>`.
Rebuilding the image afterwards is automatic — the image stages are never
stamped, precisely because any package change invalidates them.

## Things worth knowing

**glibc must match the host.** Phases 1–3 compile with the host's GCC
against the host's headers, so the guest's libc has to provide at least the
same symbol versions. `GLIBC_VER` therefore defaults to the host's glibc
version, and `00-host-check` warns loudly if you override it downwards.
This is the single most common way to end up with a system that boots to
`version 'GLIBC_2.43' not found` and nothing else.

**Everything links against the guest tree, not the host's.** `use_guest_flags`
puts `-I$LFN/usr/include` and `-L$LFN/usr/lib` in front of everything and
points `pkg-config` at the guest's `.pc` files. Without it, configure finds
the host's ncurses or OpenSSL, records a `DT_NEEDED` the guest cannot
satisfy, and the binary dies at exec time inside the VM with no useful
message.

**`check_links` is the gate that catches that.** It walks the tree, reads
each ELF object's `DT_NEEDED` and interpreter, and resolves them *by hand*
against the guest tree — deliberately not by asking `ld.so`, which would
fall back to the host's `/usr/lib` and hide the very bug being looked for.
Most stages run it before declaring success.

**Nothing may be a kernel module.** There is no module loader in this
userland and no initramfs, so `CONFIG_MODULES` is forced off and the kernel
stage refuses to continue if anything set it back on. A driver built `=m`
here is simply a driver that does not exist.

**`olddefconfig` drops symbols silently.** It will happily discard a symbol
whose dependencies are unmet and say nothing. Stage 50 asserts every
critical symbol survived and warns about the rest — that check is the
difference between "unable to mount root fs" being a five-minute fix and an
afternoon.

**init never exits.** Every step in it is non-fatal, because PID 1 exiting
is a kernel panic. If the network fails to come up you still get a shell and
can fix it from inside. `./lfn boot --rescue` skips init entirely.

**QEMU user-mode networking does not do ICMP.** Never debug it with `ping`;
use `wget`, `curl` or `ss`.

## Where to take it next

The system is rolling in the sense the doc means: there is no package
manager, so it stays current only as long as you keep pulling newer sources
and rebuilding — now from inside the guest, which is the whole point. The
obvious next moves are a small `pkg` helper for the download/configure/make
loop, a real init (s6 or OpenRC), Python and ninja/meson, and virtio-fs to
share a host directory into the guest during development.

---

Methodology and the discovery process behind LFN belong to **Maple Circuit**
([notes](https://maplecircuit.dev/lfn/linux-from-nothing.html),
[playlist](https://www.youtube.com/playlist?list=PLkoRSCZZILDO-YU9Ct-KeVEW71hzeZJu7)).
`LFN-2.md` is the Arch/zsh/virtio rework this implements.
