#!/usr/bin/env bash
# Phase 2.1b — iproute2: `ip`, `ss`, `bridge`, `tc`.
#
# init already contains the `ip link/addr/route` calls; until this stage runs
# they simply do nothing (every step in init is non-fatal).  After it, the
# guest actually gets 10.0.2.15 on the QEMU user network.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-$IPROUTE2_VER.tar.xz")
srcdir=$(extract "$tarball")

# iproute2 has no out-of-tree build; work in a copy so a re-run starts clean.
bdir="$BUILD/iproute2"
rm -rf "$bdir"; cp -a "$srcdir" "$bdir"; cd "$bdir"

step "configure iproute2 $IPROUTE2_VER"
./configure --prefix=/usr --libdir=/usr/lib || die "iproute2 configure failed"

# Whatever the probe decided, these three must be off: their libraries are on
# the host but not in the guest, and none of them is needed to bring an
# interface up.
sed -i -e 's/^HAVE_ELF:=y/HAVE_ELF:=n/' \
       -e 's/^HAVE_SELINUX:=y/HAVE_SELINUX:=n/' \
       -e 's/^HAVE_LIBBSD:=y/HAVE_LIBBSD:=n/' config.mk
step "config.mk: $(grep -E '^HAVE_(MNL|ELF|CAP|SELINUX)' config.mk | tr '\n' ' ')"

make -j"$JOBS" || die "iproute2 build failed"
frun make install DESTDIR="$LFN" PREFIX=/usr SBINDIR=/usr/bin CONFDIR=/etc/iproute2 \
  || die "iproute2 install failed"

for b in ip ss bridge; do
  [[ -x "$LFN/usr/bin/$b" ]] || die "iproute2 did not install $b"
done
check_links /usr/bin/ip || die "ip has unsatisfied dependencies"
step "guest ip: $(guest_run /usr/bin/ip -V)"

drop_build "$bdir"
ok "iproute2 $IPROUTE2_VER installed"
