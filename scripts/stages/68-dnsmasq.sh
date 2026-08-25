#!/usr/bin/env bash
# Phase 2.3 — dnsmasq as a local caching resolver, wired into init.
#
# Strictly speaking the guest can resolve names by pointing resolv.conf
# straight at QEMU's built-in forwarder (10.0.2.3).  dnsmasq is what the LFN
# notes use, it caches, and it gives the system something that looks like a
# real service to start — which is what /etc/init.d is for.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://thekelleys.org.uk/dnsmasq/dnsmasq-$DNSMASQ_VER.tar.xz")
srcdir=$(extract "$tarball")

bdir="$BUILD/dnsmasq"
rm -rf "$bdir"; cp -a "$srcdir" "$bdir"; cd "$bdir"

# No configure script.  Every optional dependency (dbus, idn, nettle, libubus)
# is off unless asked for, which is exactly what we want.
step "make dnsmasq $DNSMASQ_VER"
make -j"$JOBS" PREFIX=/usr || die "dnsmasq build failed"
frun make install PREFIX=/usr DESTDIR="$LFN" || die "dnsmasq install failed"

[[ -x "$LFN/usr/bin/dnsmasq" || -x "$LFN/usr/sbin/dnsmasq" ]] || die "dnsmasq did not install"
check_links /usr/bin/dnsmasq || die "dnsmasq has unsatisfied dependencies"

install -Dm644 /dev/stdin "$LFN/etc/dnsmasq.conf" <<'EOF'
# LFN local resolver.
# Upstreams are QEMU's user-mode forwarder first, then a public resolver so
# the same image also works under -netdev bridge or on real hardware.
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-poll
server=10.0.2.3
server=1.1.1.1
cache-size=1000
domain-needed
bogus-priv
EOF

install -Dm755 /dev/stdin "$LFN/etc/init.d/20-dnsmasq" <<'EOF'
#!/bin/zsh
# Started by init.  -u root because there is no unprivileged user yet, and
# no daemon supervision to restart it if it dies.
[[ -x /usr/bin/dnsmasq ]] || exit 0
pidof dnsmasq >/dev/null 2>&1 && exit 0
/usr/bin/dnsmasq -u root --conf-file=/etc/dnsmasq.conf --pid-file=/run/dnsmasq.pid \
  && print "dnsmasq: listening on 127.0.0.1:53"
EOF

# With a local cache running, that is what the resolver library should ask.
install -Dm644 /dev/stdin "$LFN/etc/resolv.conf" <<'EOF'
# dnsmasq (started by init) forwards to QEMU's 10.0.2.3 and caches answers.
nameserver 127.0.0.1
# Direct fallbacks in case dnsmasq is not running.
nameserver 10.0.2.3
nameserver 1.1.1.1
options timeout:2 attempts:2
EOF

step "guest dnsmasq: $(guest_run /usr/bin/dnsmasq --version | head -1)"
drop_build "$bdir"
ok "dnsmasq $DNSMASQ_VER installed and hooked into init"
