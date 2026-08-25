#!/usr/bin/env bash
# Phase 3.1 — binutils: assembler, linker, and the object-file tools.
#
# Phase 3 is where LFN stops being a cross-build and becomes a system that can
# rebuild itself.  binutils first: gcc is useless without an assembler.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz")
srcdir=$(extract "$tarball")

build_autotools binutils "$srcdir" \
  --prefix=/usr \
  --sysconfdir=/etc \
  --enable-gold=no \
  --enable-ld=default \
  --enable-plugins \
  --enable-64-bit-bfd \
  --with-system-zlib \
  --disable-nls \
  --disable-werror \
  --disable-gprofng \
  --without-gmp \
  --without-isl \
  --without-zstd \
  --with-lib-path=/usr/lib:/usr/local/lib

for b in as ld ar nm objdump ranlib readelf strip; do
  [[ -x "$LFN/usr/bin/$b" ]] || die "binutils did not install $b"
done
check_links /usr/bin/ld || die "ld has unsatisfied dependencies"
step "guest ld: $(guest_run /usr/bin/ld --version | head -1)"
ok "binutils $BINUTILS_VER installed"
