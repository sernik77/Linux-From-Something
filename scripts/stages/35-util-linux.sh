#!/usr/bin/env bash
# Phase 1.4 — util-linux: mount, umount, dmesg, blkid, fdisk, login, kill …
#
# Almost every --without- below exists for the same reason: util-linux probes
# the *host* for optional libraries (systemd, udev, libcap-ng, audit, magic,
# cryptsetup) and links whatever it finds, producing guest binaries that need
# libraries the guest does not have.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

url="https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v$UTIL_LINUX_SERIES/util-linux-$UTIL_LINUX_VER.tar.xz"
tarball=$(fetch "$url")
srcdir=$(extract "$tarball")

build_autotools util-linux "$srcdir" \
  --prefix=/usr \
  --sysconfdir=/etc \
  --runstatedir=/run \
  --disable-nls \
  --disable-static \
  --disable-rpath \
  --disable-liblastlog2 \
  --disable-pylibmount \
  --disable-bash-completion \
  --disable-chfn-chsh \
  --disable-login \
  --disable-su \
  --disable-sulogin \
  --disable-runuser \
  --without-systemd \
  --without-systemdsystemunitdir \
  --without-udev \
  --without-python \
  --without-cap-ng \
  --without-audit \
  --without-selinux \
  --without-libmagic \
  --without-cryptsetup \
  --without-readline \
  --without-utempter \
  ADJTIME_PATH=/var/lib/hwclock/adjtime

# These account-management programs are outside this minimal system's boot
# path and require PAM or libcrypt, neither of which is installed.  Remove
# copies left by an older stage run so a rebuild cannot retain host-linked
# binaries in the guest tree.
rm -f "$LFN/usr/bin/chfn" "$LFN/usr/bin/chsh" "$LFN/usr/bin/login" \
      "$LFN/usr/bin/runuser" "$LFN/usr/bin/su" "$LFN/usr/bin/sulogin"

for b in mount umount dmesg blkid lsblk fdisk mkswap kill more; do
  [[ -x "$LFN/usr/bin/$b" ]] || warn "util-linux did not install $b"
done
[[ -x "$LFN/usr/bin/mount" ]] || die "mount is missing — init cannot work without it"

check_links /usr/bin/mount || die "mount has unsatisfied dependencies"
check_links /usr/bin/dmesg || die "dmesg has unsatisfied dependencies"
step "guest mount: $(guest_run /usr/bin/mount --version | head -1)"
ok "util-linux $UTIL_LINUX_VER installed"
