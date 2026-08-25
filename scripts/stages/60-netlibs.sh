#!/usr/bin/env bash
# Phase 2.1a — the libraries iproute2 and everything after it link against.
#
# The doc lists "elfutils, libcap, zlib, zstd" here.  elfutils is left out on
# purpose: iproute2 only uses it to load BPF ELF objects, which this system
# has no kernel support for, and pulling it in drags in libarchive, bzip2 and
# a much longer build for no boot-time benefit.  HAVE_ELF is switched off in
# the iproute2 stage instead.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

# ------------------------------------------------------------------ zlib ----
tarball=$(fetch "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz")
srcdir=$(extract "$tarball")
bdir="$BUILD/zlib"; rm -rf "$bdir"; mkdir -p "$bdir"
step "configure zlib $ZLIB_VER"
( cd "$bdir" && "$srcdir/configure" --prefix=/usr ) || die "zlib configure failed"
make -C "$bdir" -j"$JOBS" || die "zlib build failed"
frun make -C "$bdir" install DESTDIR="$LFN" || die "zlib install failed"
rm -f "$LFN/usr/lib/libz.a"
drop_build "$bdir"
[[ -e "$LFN/usr/lib/libz.so.1" ]] || die "libz.so.1 missing"

# ---------------------------------------------------------------- libmnl ----
tarball=$(fetch "https://www.netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2")
srcdir=$(extract "$tarball")
build_autotools libmnl "$srcdir" --prefix=/usr --disable-static
[[ -e "$LFN/usr/lib/libmnl.so.0" ]] || die "libmnl.so.0 missing"

# ---------------------------------------------------------------- libcap ----
# Plain Makefile, no configure.  PAM and Go bindings are explicitly off; both
# would look for host libraries that do not exist in the guest.
tarball=$(fetch "https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-$LIBCAP_VER.tar.xz")
srcdir=$(extract "$tarball")
step "make libcap $LIBCAP_VER"
make -C "$srcdir" -j"$JOBS" prefix=/usr lib=lib PAM_CAP=no GOLANG=no \
  || die "libcap build failed"
frun make -C "$srcdir" install DESTDIR="$LFN" prefix=/usr lib=lib PAM_CAP=no GOLANG=no \
  || die "libcap install failed"
rm -f "$LFN/usr/lib/libcap.a" "$LFN/usr/lib/libpsx.a"
[[ -e "$LFN/usr/lib/libcap.so.2" ]] || die "libcap.so.2 missing"

check_links /usr/lib/libcap.so.2 || die "libcap has unsatisfied dependencies"
ok "zlib $ZLIB_VER, libmnl 1.0.5, libcap $LIBCAP_VER installed"
