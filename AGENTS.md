# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

An unattended, idempotent implementation of `LFN-2.md` ("Linux From Nothing", Arch-host edition): a
bootable, self-hosting Linux system built entirely from source under QEMU/KVM — kernel, glibc, zsh
(as `/bin/sh`), merged `/usr`, virtio-first, no package manager. `LFN-2.md` is the human-driven
source doc; everything under `scripts/` turns it into 24 numbered, resumable build stages plus a
serial-console test harness that boots the guest and asserts it actually works.

## Commands

```bash
./lfn list                 # every stage and whether it's done (stamped)
./lfn build                # run all pending stages in order
./lfn build 72-gcc         # run one stage — by number, by name, or "num-name"
./lfn redo 50-kernel        # clear a stage's stamp and rebuild it (and nothing before it)
./lfn status                # tree size, kernel/rootfs artefacts, free space
./lfn check                 # walk the installed tree, verify every ELF's deps resolve in-tree
./lfn shell                  # host shell with the build env exported

./lfn boot                  # interactive, direct kernel boot (-kernel, fast dev path)
./lfn boot --disk           # boot through GRUB off the partitioned disk image
./lfn boot --rescue         # init=/bin/zsh, when init itself is broken
./lfn boot --debug          # earlyprintk, when the kernel dies before init

./lfn test                  # run all tests/*.expect against the image
./lfn test 01-boot --echo   # one test, with guest serial output echoed live
```

Stage logs land in `work/logs/<stage>.log`. A build can be interrupted (Ctrl-C) and resumed with
`./lfn build` — it picks up at the first unstamped stage. `work/` holds every generated artefact
(sources, build dirs, the guest tree, images, logs, stamps) and is **not** tracked in git; it lives
one level above any worktree (see Architecture) so a throwaway worktree never takes the build with
it.

There is no separate lint/test-framework command — "tests" are the `.expect` boot scripts run via
`./lfn test`, and correctness of each stage is enforced inline (mostly `check_links`, `guest_run`,
and stage-specific assertions) rather than by a standalone test suite.

## Architecture

**The driver (`lfn`)** sources `lfn.conf` (paths, versions, QEMU sizing, kernel symbol lists) and
`scripts/lib/common.sh` (shared helpers), then dispatches to one `scripts/stages/NN-name.sh` file
per subcommand argument. Each stage is a plain bash script, run with `bash "$f"` and its output
teed to a per-stage log; a stage is skipped if `work/stamps/<name>` exists. **Disk-image stages
(`*-image`, `*-disk`) are never stamped** — they're a pure function of the guest tree, so any later
stage that changes the tree must invalidate them.

**Work directory placement.** `lfn` computes `LFN_WORK` outside the checkout: if invoked from
inside `.Codex/worktrees/<name>/`, work goes to the repo root's `../work` (sibling of
`.Codex/`), not inside the worktree. This is deliberate — worktrees are disposable, build output
(tens of GB) is not.

**Root-free image construction is the central trick of this codebase.** LFN-2.md assumes a human
with `sudo`: `modprobe nbd`, `qemu-nbd`, `mount`, `cp -a`, `grub-install /dev/nbdX`. None of that is
available unprivileged, so every stage substitutes:
- `fakeroot` (persistent state DB at `$FAKEROOT_STATE`, via the `frun` helper) instead of running
  `make install` as root — records root:root ownership without actually being root.
- `mke2fs -d <dir>` instead of loop-mounting an image and `cp -a`-ing into it — builds the ext4
  filesystem straight from a populated directory tree.
- `mke2fs -E offset=…` + `sfdisk` on a raw file + `grub-mkimage`/`grub-bios-setup` on that file
  instead of partitioning/mounting a block device.
- `ldconfig` deferred to guest first boot (in `/usr/bin/init`) instead of `ldconfig -r $LFN` on the
  host — `-r` chroots, which fakeroot cannot fake.

See the table in `README.md` ("The one deliberate deviation: no root") for the doc-vs-here mapping.

**The guest tree (`$LFN`, i.e. `work/root/`) is built to run under the *host's* toolchain**, so two
invariants matter everywhere in `scripts/lib/common.sh` and the stages:
1. **glibc must match the host.** Phases 1–3 compile with the host's GCC against host headers, so
   guest glibc must provide at least the same symbol versions. `GLIBC_VER` in `lfn.conf` defaults
   to the host's own version (`host_glibc_version()`); overriding it downward is a footgun that
   surfaces at boot as `version 'GLIBC_2.xx' not found`.
2. **Every build links against the guest tree, never the host's.** `use_guest_flags()` (in
   `common.sh`) puts `-I$LFN/usr/include`/`-L$LFN/usr/lib` first and points `PKG_CONFIG_LIBDIR`/
   `PKG_CONFIG_SYSROOT_DIR` at the guest tree, so configure can't silently record a host-only
   `DT_NEEDED`. Nearly every stage calls this before building.

**Verification primitives in `common.sh`**, used throughout the stages:
- `guest_run <path> [args]` — runs a guest binary *on the host* through the guest's own dynamic
  loader (`ld-linux-x86-64.so.2 --library-path $LFN/usr/lib`). The cheapest possible "will this run
  in the VM?" check, used e.g. to verify glibc/zsh/ncurses right after install.
- `check_links [scope]` — walks ELF objects and resolves `DT_NEEDED`/`PT_INTERP` **by hand** via
  `readelf`, deliberately not through `ld.so` (which falls back to the host's `/usr/lib` and would
  hide exactly the missing-dependency bug being checked for). Exposed as `./lfn check`.
- `sanitize_tree()` — strips baked-in host paths (`$LFN/usr/lib`, `$LFN/usr/include`) out of
  installed `.pc`/`.la` files after every `build_autotools` install, so in-guest rebuilds later
  (Phase 3 self-hosting) don't inherit host-only search paths.

**Stage/phase mapping** (full table in `README.md`): `00`/`05` host check + merged-`/usr` skeleton
→ `10` kernel headers → `15` glibc → `20` ncurses → `25` zsh → `30`/`35`/`40` coreutils/util-linux/
nano → `45` `/etc` + init → `50` kernel image → `60`–`68` networking (iproute2, OpenSSL+CA roots,
wget, dnsmasq) → `70`–`75` self-hosting toolchain (binutils, GCC, make/sed/grep/awk/tar/perl/…) →
`80`/`82` curl/git/strace → `90`/`92` GRUB + partitioned disk → `99` plain ext4 image. Phase 3
(`70`–`75`) is the milestone: once GCC/make exist in-guest, the system builds upstream tarballs on
itself with no host and no DESTDIR — asserted by `tests/03-selfhost.expect`.

**Known, intentional deviation from `LFN-2.md`:** ncurses is built *without* `--with-termlib`
(see the long comment in `scripts/stages/20-ncurses.sh`). Splitting out `libtinfo` matches the doc
but breaks builds that probe the host's un-split ncurses (`ncursesw6-config` reports `-lncursesw`
alone on Arch) — the guest then either fails to link or resolves against the host's copy at
runtime. `libtinfo(w).so.6` are provided as symlinks to `libncurses(w).so.6` instead, matching how
Arch itself ships them.

**Init (`/usr/bin/init`, written by stage `45`)** is zsh, wraps every step in a non-fatal `try()`
(PID 1 exiting is a kernel panic — it must never exit), builds the ldconfig cache on first boot
(can't be done at build time — `ldconfig -r` needs a real chroot), brings up the virtio-net
interface, runs `/etc/init.d/*` hooks, prints the sentinel `LFN-INIT-OK <uname -r>` for the test
harness, then `exec`s an interactive login shell.

**Kernel config (`scripts/stages/50-kernel.sh`)** starts from `tinyconfig`, applies
`KERNEL_ENABLE`/`KERNEL_DISABLE` from `lfn.conf` via `scripts/config`, runs `olddefconfig`, then
explicitly asserts every symbol in a `critical=(…)` list actually survived — `olddefconfig` silently
drops symbols with unmet dependencies, so this assertion is what turns "unable to mount root fs"
into a stage failure instead of a runtime mystery. `CONFIG_MODULES=y` is a hard stage failure: there
is no module loader or initramfs in this userland.

**Test harness (`scripts/lib/qemu_expect.py`)** is a dependency-free expect clone (no `pexpect`)
driving QEMU's serial console: directives `TIMEOUT`/`EXPECT`/`SEND`/`FAIL`/`SLEEP` in `tests/*.expect`
files, run via `scripts/test.sh` against a reflinked copy of the built image so tests don't mutate
the real artefact. `EXPECT` patterns are regexes checked against accumulated output; `FAIL` patterns
(e.g. `Kernel panic`) abort immediately if seen at any point. QEMU user-mode networking does not
forward ICMP reliably — tests use `wget`/`ss`, never `ping`.

## Configuration

`lfn.conf` is the single file to edit for version bumps, `JOBS`, `MIN_FREE_GB`, QEMU sizing
(`QEMU_MEM`/`QEMU_SMP`/`QEMU_SSH_PORT`), and the kernel `KERNEL_ENABLE`/`KERNEL_DISABLE` arrays.
After bumping a package version, `./lfn redo <stage>` rebuilds just that stage forward; the image
stages pick up the change automatically since they're never stamped.
