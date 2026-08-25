#!/usr/bin/env bash
# Phase 3.2 — GCC.  The package that turns LFN into a self-hosting system.
#
# Notes on the choices below:
#   * no bootstrap.  A bootstrap builds the compiler three times to prove the
#     result is independent of the compiler that built it.  That matters when
#     you distrust the host toolchain; here the host is a current Arch gcc and
#     the guest runs the same architecture, so it costs 40 minutes for nothing.
#     `./lfn redo 72-gcc` with GCC_BOOTSTRAP=1 if you want the full thing.
#   * gmp/mpfr/mpc are unpacked into the source tree, which is how GCC expects
#     to find them when they are not installed system-wide.
#   * sanitizers and vtv are off: large, slow to build, and useless without a
#     much richer runtime than this system has.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

# GCC 16 changed its default C++ mode enough that u8 literals have type
# char8_t while GCC 15's bundled libcody still passes them to char-based
# interfaces.  GCC 15 builds correctly with the pre-char8_t semantics; apply
# that compatibility switch only to the host C++ compiler used to build it.
export CXXFLAGS="-g -O2 -fno-char8_t ${CXXFLAGS_EXTRA:-}"

require_space 30

tarball=$(fetch "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz")
srcdir=$(extract "$tarball")

# ---------------------------------------------------------- prerequisites ---
for dep in "gmp:$GMP_VER:https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VER.tar.xz" \
           "mpfr:$MPFR_VER:https://ftp.gnu.org/gnu/mpfr/mpfr-$MPFR_VER.tar.xz" \
           "mpc:$MPC_VER:https://ftp.gnu.org/gnu/mpc/mpc-$MPC_VER.tar.gz"; do
  name=${dep%%:*}; rest=${dep#*:}; ver=${rest%%:*}; url=${rest#*:}
  if [[ ! -d "$srcdir/$name" ]]; then
    t=$(fetch "$url")
    d=$(extract "$t")
    step "linking $name-$ver into the gcc tree"
    cp -a "$d" "$srcdir/$name"
  else
    step "have $name in gcc tree"
  fi
done

bdir="$BUILD/gcc"
rm -rf "$bdir"; mkdir -p "$bdir"; cd "$bdir"

boot_opt=--disable-bootstrap
[[ ${GCC_BOOTSTRAP:-0} == 1 ]] && boot_opt=--enable-bootstrap

step "configure gcc $GCC_VER ($boot_opt)"
"$srcdir/configure" \
  --prefix=/usr \
  --libdir=/usr/lib \
  --libexecdir=/usr/lib \
  --enable-languages=c,c++ \
  --enable-shared \
  --enable-threads=posix \
  --enable-__cxa_atexit \
  --enable-default-pie \
  --enable-default-ssp \
  --enable-linker-build-id \
  --disable-multilib \
  --disable-nls \
  --disable-libsanitizer \
  --disable-libvtv \
  --disable-werror \
  --without-isl \
  --without-zstd \
  --with-system-zlib \
  --with-linker-hash-style=gnu \
  --build=x86_64-pc-linux-gnu \
  "$boot_opt" \
  || die "gcc configure failed"

step "make gcc (-j$JOBS) — expect this to take a while"
make -j"$JOBS" || die "gcc build failed"

step "install gcc -> \$LFN"
frun make install-strip DESTDIR="$LFN" || die "gcc install failed"

# A native GCC build runs fixincludes against the host's /usr/include before
# DESTDIR is applied.  Those fixed copies are host packages, not part of the
# guest (on Arch this included pthread.h plus headers from X11, Boost, NSS,
# ntfs-3g, and others).  Linux/glibc needs none of these fixups; keeping the
# directory would also make it precede the guest's real /usr/include.
rm -rf "$LFN/usr/lib/gcc/x86_64-pc-linux-gnu/$GCC_VER/include-fixed"
sanitize_tree

# ------------------------------------------------------------- verify -------
for f in usr/bin/gcc usr/bin/g++ usr/lib/libgcc_s.so.1 usr/lib/libstdc++.so.6; do
  [[ -e "$LFN/$f" ]] || die "gcc install incomplete: /$f"
done
# cc is what half of the world's configure scripts actually invoke.
ln -sfn gcc "$LFN/usr/bin/cc"

check_links /usr/bin/gcc  || die "gcc has unsatisfied dependencies"
check_links /usr/bin/cc1  2>/dev/null || true
step "guest gcc: $(guest_run /usr/bin/gcc --version | head -1)"

drop_build "$bdir"
ok "gcc $GCC_VER installed — the guest can now compile"
