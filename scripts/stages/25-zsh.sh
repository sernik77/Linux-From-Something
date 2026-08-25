#!/usr/bin/env bash
# Phase 1.2 — zsh, the system shell.  /bin/sh points at it.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://www.zsh.org/pub/zsh-$ZSH_VER.tar.xz")
srcdir=$(extract "$tarball")

bdir="$BUILD/zsh"; rm -rf "$bdir"; mkdir -p "$bdir"
step "configure zsh $ZSH_VER"
( cd "$bdir" && "$srcdir/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --enable-etcdir=/etc/zsh \
    --enable-multibyte \
    --with-tcsetpgrp \
    --enable-cap=no \
    --disable-gdbm \
    --enable-function-subdirs \
) || die "zsh configure failed"

make -C "$bdir" -j"$JOBS" || die "zsh build failed"
frun make -C "$bdir" install DESTDIR="$LFN" || die "zsh install failed"

# /bin/sh -> zsh, and a real /bin/zsh path for the init shebang.
ln -sfn zsh "$LFN/usr/bin/sh"

[[ -x "$LFN/usr/bin/zsh" ]] || die "zsh binary missing"
check_links /usr/bin/zsh || die "zsh has dependencies the guest tree cannot satisfy"

# Run the freshly built shell on the host, but through the *guest* loader and
# restricted to the *guest* libraries.  If this prints OK the shell will run
# inside the VM; if it does not, no amount of QEMU debugging would have helped.
out=$(guest_run /usr/bin/zsh -c 'print -r -- ZSH-OK $ZSH_VERSION')
step "guest zsh under guest loader: $out"
[[ $out == ZSH-OK* ]] || die "guest zsh did not run: $out"

drop_build "$bdir"
ok "zsh $ZSH_VER installed and verified, /bin/sh -> zsh"
