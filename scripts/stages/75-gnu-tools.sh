#!/usr/bin/env bash
# Phase 3.3 — the rest of the build environment.
#
# Everything a configure script assumes exists: make, sed, grep, awk, tar,
# the compressors, diff, find, patch, bison, file, pkg-config, perl.  Without
# this stage the guest has a compiler but still cannot build anything, which
# is a very frustrating place to stop.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

require_space 15

# pkg <name> <url> [configure args...]
pkg() {
  local name=$1 url=$2; shift 2
  if [[ -f "$STAMPS/pkg-$name" ]]; then step "have $name"; return 0; fi
  msg "$name"
  local t d
  t=$(fetch "$url")
  d=$(extract "$t")
  if [[ $name == m4 ]]; then
    # glibc 2.43+ exposes the C23 const-preserving functions as _Generic
    # macros whenever _GNU_SOURCE is set.  m4 1.4.20's bundled gnulib then
    # tries to redeclare the same names for GCC >= 15 without first removing
    # those macros, so the declarations expand into invalid C.  Undefine only
    # the affected function-like macros before gnulib's N3322 declarations.
    sed -i '/\/\* Declarations for ISO C N3322\.  \*\//a\#undef memchr\n#undef memrchr' \
      "$d/lib/string.in.h"
    sed -i '/\/\* Declarations for ISO C N3322\.  \*\//a\#undef bsearch' \
      "$d/lib/stdlib.in.h"
    sed -i '/\/\* Declarations for ISO C N3322\.  \*\//a\#undef wmemchr' \
      "$d/lib/wchar.in.h"
  elif [[ $name == gawk ]]; then
    # With --disable-extensions gawk 5.3.2 does not generate
    # extension/Makefile, but its final optimization pass still loops over
    # that file and makes configure fail.  Keep the pass for the two
    # Makefiles that actually exist.
    sed -i 's/for i in \. support extension/for i in . support/g' \
      "$d/configure"
  fi
  build_autotools "$name" "$d" "$@"
  set_stamp "pkg-$name"
}

# ---------------------------------------------------------------------------
# Order matters a little: m4 before bison (bison uses it), make early so the
# rest is quick to redo by hand if something needs a second attempt.
# ---------------------------------------------------------------------------
pkg make "https://ftp.gnu.org/gnu/make/make-$MAKE_VER.tar.gz" \
    --prefix=/usr --disable-nls --without-guile

pkg m4 "https://ftp.gnu.org/gnu/m4/m4-$M4_VER.tar.xz" \
    --prefix=/usr --disable-nls

pkg sed "https://ftp.gnu.org/gnu/sed/sed-$SED_VER.tar.xz" \
    --prefix=/usr --disable-nls --disable-acl

pkg grep "https://ftp.gnu.org/gnu/grep/grep-$GREP_VER.tar.xz" \
    --prefix=/usr --disable-nls

pkg gawk "https://ftp.gnu.org/gnu/gawk/gawk-$GAWK_VER.tar.xz" \
    --prefix=/usr --disable-nls --disable-extensions --disable-mpfr \
    --without-readline

pkg diffutils "https://ftp.gnu.org/gnu/diffutils/diffutils-$DIFFUTILS_VER.tar.xz" \
    --prefix=/usr --disable-nls

pkg findutils "https://ftp.gnu.org/gnu/findutils/findutils-$FINDUTILS_VER.tar.xz" \
    --prefix=/usr --disable-nls --localstatedir=/var/lib/locate

pkg patch "https://ftp.gnu.org/gnu/patch/patch-$PATCH_VER.tar.xz" \
    --prefix=/usr --disable-nls --disable-xattr

pkg tar "https://ftp.gnu.org/gnu/tar/tar-$TAR_VER.tar.xz" \
    --prefix=/usr --disable-nls --without-posix-acls

pkg gzip "https://ftp.gnu.org/gnu/gzip/gzip-$GZIP_VER.tar.xz" \
    --prefix=/usr --disable-nls

pkg xz "https://github.com/tukaani-project/xz/releases/download/v$XZ_VER/xz-$XZ_VER.tar.xz" \
    --prefix=/usr --disable-nls --disable-static

pkg bison "https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz" \
    --prefix=/usr --disable-nls \
    ac_cv_libtextstyle=no gl_cv_lib_readline=no \
    ac_cv_header_readline_readline_h=no ac_cv_header_readline_history_h=no

pkg file "https://astron.com/pub/file/file-$FILE_VER.tar.gz" \
    --prefix=/usr --disable-nls --disable-static \
    --disable-libseccomp --disable-zstdlib

pkg pkgconf "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_VER.tar.xz" \
    --prefix=/usr --disable-static

# ----------------------------------------------------------------- bzip2 ----
# Plain Makefile, and the shared library needs a separate pass.
if [[ ! -f "$STAMPS/pkg-bzip2" ]]; then
  msg "bzip2"
  t=$(fetch "https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VER.tar.gz")
  d=$(extract "$t")
  b="$BUILD/bzip2"; rm -rf "$b"; cp -a "$d" "$b"; cd "$b"
  make -f Makefile-libbz2_so -j"$JOBS" || die "bzip2 shared build failed"
  make clean >/dev/null
  make -j"$JOBS" || die "bzip2 build failed"
  frun make install PREFIX="$LFN/usr" || die "bzip2 install failed"
  cp -a libbz2.so.* "$LFN/usr/lib/"
  ln -sfn "libbz2.so.$BZIP2_VER" "$LFN/usr/lib/libbz2.so.1.0"
  ln -sfn libbz2.so.1.0 "$LFN/usr/lib/libbz2.so"
  drop_build "$b"
  set_stamp pkg-bzip2
fi

# ------------------------------------------------------------------ perl ----
# Not autotools; its own Configure.  Needed by autoconf, automake, git's build
# and a surprising number of test suites.
if [[ ! -f "$STAMPS/pkg-perl" ]]; then
  msg "perl $PERL_VER"
  t=$(fetch "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.xz")
  d=$(extract "$t")
  b="$BUILD/perl"; rm -rf "$b"; cp -a "$d" "$b"; cd "$b"
  step "Configure perl"
  ./Configure -des \
    -Dprefix=/usr \
    -Dvendorprefix=/usr \
    -Dprivlib="/usr/lib/perl5/${PERL_VER%.*}/core_perl" \
    -Darchlib="/usr/lib/perl5/${PERL_VER%.*}/core_perl" \
    -Dsitelib="/usr/lib/perl5/${PERL_VER%.*}/site_perl" \
    -Dsitearch="/usr/lib/perl5/${PERL_VER%.*}/site_perl" \
    -Dusethreads \
    -Duseshrplib \
    -Dlibswanted='pthread dl m util c' \
    -Dcc=gcc \
    || die "perl Configure failed"
  make -j"$JOBS" || die "perl build failed"
  # A retry with fewer optional libraries must not retain extension modules
  # (notably GDBM_File) from a previous host-contaminated installation.
  rm -rf "$LFN/usr/lib/perl5/${PERL_VER%.*}"
  frun make install DESTDIR="$LFN" || die "perl install failed"
  ln -sfn "perl5/${PERL_VER%.*}/core_perl/CORE/libperl.so" \
    "$LFN/usr/lib/libperl.so"
  drop_build "$b"
  set_stamp pkg-perl
fi

# --------------------------------------------------------------- verify -----
missing=()
for b in make m4 sed grep awk tar gzip xz bzip2 diff find patch bison file \
         pkgconf perl; do
  [[ -x "$LFN/usr/bin/$b" ]] || missing+=("$b")
done
((${#missing[@]} == 0)) || die "not installed: ${missing[*]}"

# pkg-config is the name every configure script actually calls.
[[ -e "$LFN/usr/bin/pkg-config" ]] || ln -sfn pkgconf "$LFN/usr/bin/pkg-config"

check_links || die "some installed binaries have unsatisfied dependencies"
step "guest make: $(guest_run /usr/bin/make --version | head -1)"
step "guest perl: $(guest_run /usr/bin/perl -e 'print "perl $]\n"')"
ok "build environment complete"
