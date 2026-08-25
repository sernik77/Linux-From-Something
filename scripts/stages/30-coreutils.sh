#!/usr/bin/env bash
# Phase 1.3 — coreutils.
#
# libcap and SELinux are switched off deliberately: neither library exists in
# the guest yet, and configure would otherwise link against the host's copies
# and produce binaries that cannot start inside the VM.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://ftp.gnu.org/gnu/coreutils/coreutils-$COREUTILS_VER.tar.xz")
srcdir=$(extract "$tarball")

build_autotools coreutils "$srcdir" \
  --prefix=/usr \
  --disable-nls \
  --without-selinux \
  --disable-libcap \
  --disable-acl \
  --disable-xattr \
  --without-libgmp \
  --without-openssl \
  --disable-year2038-required \
  --enable-install-program=hostname \
  --enable-no-install-program=kill,uptime

for b in ls cp mv rm cat echo mkdir chmod ln date df du head tail sort wc \
         install printf sleep stty tee touch uname id; do
  [[ -x "$LFN/usr/bin/$b" ]] || die "coreutils did not install $b"
done

check_links /usr/bin/ls || die "coreutils binaries have unsatisfied dependencies"
step "guest ls: $(guest_run /usr/bin/ls --version | head -1)"
ok "coreutils $COREUTILS_VER installed"
