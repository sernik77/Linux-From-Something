#!/usr/bin/env bash
# Phase 4.2 — git and strace.
#
# With these two the guest is self-sufficient: it can clone upstream sources
# and it can find out why something fails.  The LFN debugging loop is
#     strace -o /tmp/t.log <cmd>  ->  grep ENOSYS  ->  enable the symbol
#     ->  rebuild the kernel *inside* LFN  ->  reboot
# and `./lfn build 50-kernel` on the host does the same thing the fast way.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

# ------------------------------------------------------------------- git ----
tarball=$(fetch "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.xz")
srcdir=$(extract "$tarball")

bdir="$BUILD/git"; rm -rf "$bdir"; cp -a "$srcdir" "$bdir"; cd "$bdir"

# git's build system is its own thing; NO_* switches replace configure flags.
step "make git $GIT_VER"
make_opts=(
  prefix=/usr
  CURLDIR="$LFN/usr"
  NO_TCLTK=1
  NO_GETTEXT=1
  NO_PERL_CPAN_FALLBACKS=1
  NO_INSTALL_HARDLINKS=1
  INSTALL_SYMLINKS=1
  USE_LIBPCRE2=1
  PERL_PATH=/usr/bin/perl
  SHELL_PATH=/bin/sh
)
make -j"$JOBS" "${make_opts[@]}" || die "git build failed"
frun make install DESTDIR="$LFN" "${make_opts[@]}" || die "git install failed"

[[ -x "$LFN/usr/bin/git" ]] || die "git did not install"
check_links /usr/bin/git || die "git has unsatisfied dependencies"
step "guest git: $(guest_run /usr/bin/git --version)"

install -Dm644 /dev/stdin "$LFN/etc/gitconfig" <<'EOF'
[user]
	name = LFN
	email = root@lfn
[init]
	defaultBranch = main
[http]
	sslCAInfo = /etc/ssl/certs/ca-certificates.crt
[safe]
	directory = *
EOF
drop_build "$bdir"

# ---------------------------------------------------------------- strace ----
tarball=$(fetch "https://github.com/strace/strace/releases/download/v$STRACE_VER/strace-$STRACE_VER.tar.xz")
srcdir=$(extract "$tarball")

# strace 6.18 predates the Linux 7.2 UAPI shipped in this tree.  In addition
# to renamed input properties, io_uring structures have grown and trigger
# deliberate size assertions in strace.  Its release tarball includes the
# matching UAPI snapshot specifically for building against newer kernels.
# Also undo the spelling used by Linux 7.2 if a resumed build has a source
# cache left behind by an earlier compatibility attempt.
sed -i 's/INPUT_PROP_PRESSUREPAD/INPUT_PROP_HAPTIC_TOUCHPAD/g' \
  "$srcdir/src/xlat/evdev_prop.in" "$srcdir/src/xlat/evdev_prop.h"
build_autotools strace "$srcdir" \
  --prefix=/usr \
  --enable-bundled=yes \
  --disable-mpers \
  --without-libunwind \
  --without-libdw \
  --without-libselinux

[[ -x "$LFN/usr/bin/strace" ]] || die "strace did not install"
check_links /usr/bin/strace || die "strace has unsatisfied dependencies"
step "guest strace: $(guest_run /usr/bin/strace --version | head -1)"

ok "git $GIT_VER and strace $STRACE_VER installed"
