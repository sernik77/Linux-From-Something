#!/usr/bin/env bash
# Phase 1.1b — configure and build the kernel.
#
# The doc drives menuconfig by hand; that cannot be scripted, so the same
# result is produced with scripts/config on top of tinyconfig, followed by
# olddefconfig.  The important part is the assertion afterwards: olddefconfig
# silently drops any symbol whose dependencies are unmet, and a driver that
# quietly vanished shows up much later as "unable to mount root fs".
source "$LFN_PROJ/scripts/lib/prologue.sh"

kdir="$SRC/linux"
[[ -d $kdir ]] || die "kernel source missing — run stage 10 first"
kbuild="$BUILD/linux"
mkdir -p "$kbuild"
cd "$kdir"

# An older stage-10 run may have left ignored headers_install output in the
# checkout.  Kbuild rejects an O= build in that state.  mrproper removes only
# generated build artefacts; it does not revert tracked source changes.
step "cleaning in-tree Kbuild artefacts"
make -s mrproper

step "tinyconfig base"
make -s O="$kbuild" tinyconfig

cfg() { ./scripts/config --file "$kbuild/.config" "$@"; }

step "enabling ${#KERNEL_ENABLE[@]} symbols, disabling ${#KERNEL_DISABLE[@]}"
for s in "${KERNEL_ENABLE[@]}";  do cfg --enable  "$s"; done
for s in "${KERNEL_DISABLE[@]}"; do cfg --disable "$s"; done

# A console on ttyS0 from the very first line of output, and no reboot loop if
# the root filesystem cannot be found.
cfg --set-str CMDLINE ""
cfg --disable CMDLINE_BOOL

step "olddefconfig (resolving dependencies)"
make -s O="$kbuild" olddefconfig

# ------------------------------------------------------- verify the config ---
# Without these the machine does not boot at all, so they are fatal.
critical=(
  64BIT SMP MULTIUSER PRINTK BLOCK MSDOS_PARTITION EXT4_FS PROC_FS SYSFS
  TMPFS SHMEM DEVTMPFS DEVTMPFS_MOUNT BINFMT_ELF BINFMT_SCRIPT
  TTY UNIX98_PTYS SERIAL_8250 SERIAL_8250_CONSOLE
  PCI VIRTIO_PCI VIRTIO_BLK FUTEX EPOLL EVENTFD SIGNALFD TIMERFD
  NET UNIX INET PACKET POSIX_TIMERS
)
missing=()
for s in "${critical[@]}"; do
  grep -qx "CONFIG_$s=y" "$kbuild/.config" || missing+=("$s")
done
if ((${#missing[@]})); then
  printf '  -> MISSING: %s\n' "${missing[@]}" >&2
  die "critical kernel symbols did not survive olddefconfig"
fi

# The rest are quality-of-life; report but do not stop.
soft=()
for s in "${KERNEL_ENABLE[@]}"; do
  grep -qx "CONFIG_$s=y" "$kbuild/.config" || soft+=("$s")
done
((${#soft[@]})) && warn "not enabled (dependency unmet or symbol renamed): ${soft[*]}"

# Nothing may be a module: there is no module loader and no initramfs.
if grep -q '^CONFIG_MODULES=y' "$kbuild/.config"; then
  die "CONFIG_MODULES=y — anything =m would silently not exist at boot"
fi

# ------------------------------------------------------------------ build ----
rel=$(make -s O="$kbuild" kernelrelease)
step "building linux $rel (-j$JOBS)"
make -s O="$kbuild" -j"$JOBS" bzImage || die "kernel build failed"

install -Dm644 "$kbuild/arch/x86/boot/bzImage" "$OUT/bzImage"
install -Dm644 "$kbuild/arch/x86/boot/bzImage" "$LFN/boot/bzImage"
install -Dm644 "$kbuild/.config"               "$LFN/boot/config-$rel"
install -Dm644 "$kbuild/System.map"            "$LFN/boot/System.map-$rel"
printf '%s\n' "$rel" > "$LFN_WORK/.kernel-release"

step "bzImage $(du -h "$OUT/bzImage" | cut -f1), $(grep -c '=y' "$kbuild/.config") options enabled"
ok "kernel $rel built"
