#!/usr/bin/env bash
# Phase 1.6 — glibc, from a real release tarball (never git).
#
# Built *before* everything else in userland, even though the doc lists it
# sixth: it provides the headers, the C runtime and the dynamic loader that
# every later package links against, and it is the one package whose version
# is not free to choose (see lfn.conf).
source "$LFN_PROJ/scripts/lib/prologue.sh"

tarball=$(fetch "https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VER.tar.xz")
srcdir=$(extract "$tarball")

bdir="$BUILD/glibc"
rm -rf "$bdir"; mkdir -p "$bdir"; cd "$bdir"

# Pin every install directory into the merged /usr/lib.  Left alone, glibc
# scatters itself over /lib, /lib64 and /sbin depending on the multilib
# defaults, which then interacts badly with the symlink farm.
cat > configparms <<'EOF'
slibdir=/usr/lib
rtlddir=/usr/lib
sbindir=/usr/bin
rootsbindir=/usr/bin
EOF

step "configure glibc $GLIBC_VER"
"$srcdir/configure" \
  --prefix=/usr \
  --libdir=/usr/lib \
  --libexecdir=/usr/lib \
  --with-headers="$LFN/usr/include" \
  --enable-kernel=6.1 \
  --enable-stack-protector=strong \
  --disable-werror \
  --disable-nscd \
  --without-selinux \
  --without-gd \
  libc_cv_slibdir=/usr/lib \
  || die "glibc configure failed"

step "make glibc (-j$JOBS) — this is the long one"
make -j"$JOBS" || die "glibc build failed"

# glibc's install rule finishes by running `ldconfig -r $DESTDIR`, which
# chroots.  fakeroot does not fake chroot(), so that last step fails for an
# unprivileged build.  Everything before it is what we actually need, so the
# install is judged by its artefacts instead of its exit status.
step "install glibc -> \$LFN"
set +e
frun make install DESTDIR="$LFN" > "$LOGS/glibc-install.log" 2>&1
rc=$?
set -e
if (( rc != 0 )); then
  if grep -qiE 'ldconfig|chroot' <(tail -20 "$LOGS/glibc-install.log"); then
    warn "make install returned $rc at the ldconfig step (expected without root)"
    warn "the loader cache is generated inside the guest on first boot instead"
  else
    tail -30 "$LOGS/glibc-install.log" >&2
    die "glibc install failed for a reason other than ldconfig"
  fi
fi

for f in usr/lib/libc.so.6 usr/lib/ld-linux-x86-64.so.2 usr/lib/libm.so.6 \
         usr/lib/libpthread.so.0 usr/include/stdio.h usr/bin/ldd; do
  [[ -e "$LFN/$f" ]] || die "glibc install incomplete: /$f is missing"
done

# The loader must also be reachable under the path the host compiler bakes
# into every binary it produces.
[[ -e "$LFN/lib64/ld-linux-x86-64.so.2" ]] \
  || die "/lib64/ld-linux-x86-64.so.2 unreachable — check the skeleton symlinks"

step "installed glibc reports: $(guest_run /usr/bin/ldd --version | head -1)"

# A libc that cannot run a static test binary is not worth continuing with.
cat > "$BUILD/.glibc-check.c" <<'EOF'
#include <stdio.h>
#include <gnu/libc-version.h>
int main(void) { printf("glibc runtime %s\n", gnu_get_libc_version()); return 0; }
EOF
gcc -o "$BUILD/.glibc-check" "$BUILD/.glibc-check.c"
out=$("$LFN/usr/lib/ld-linux-x86-64.so.2" --library-path "$LFN/usr/lib" "$BUILD/.glibc-check")
step "host-compiled binary under guest loader: $out"
[[ $out == *"$GLIBC_VER"* ]] || die "guest loader reported '$out', expected $GLIBC_VER"
rm -f "$BUILD/.glibc-check" "$BUILD/.glibc-check.c"

drop_build "$bdir"
ok "glibc $GLIBC_VER installed and verified"
