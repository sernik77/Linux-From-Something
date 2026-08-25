#!/usr/bin/env bash
# Phase 1.5 — nano, so the guest can edit its own files.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

major=${NANO_VER%%.*}
tarball=$(fetch "https://nano-editor.org/dist/v$major/nano-$NANO_VER.tar.xz")
srcdir=$(extract "$tarball")

build_autotools nano "$srcdir" \
  --prefix=/usr \
  --sysconfdir=/etc \
  --disable-nls \
  --enable-utf8 \
  --disable-libmagic

[[ -x "$LFN/usr/bin/nano" ]] || die "nano did not install"
check_links /usr/bin/nano || die "nano has unsatisfied dependencies"

install -Dm644 /dev/stdin "$LFN/etc/nanorc" <<'EOF'
# Minimal nanorc for LFN.  Everything else is discoverable via M-x / ^G.
set autoindent
set tabsize 4
set linenumbers
set constantshow
EOF

step "guest nano: $(guest_run /usr/bin/nano --version | head -1)"
ok "nano $NANO_VER installed"
