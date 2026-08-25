#!/usr/bin/env bash
# Phase 4.1 — expat and curl.
#
# curl is the package the LFN series uses to discover missing kernel features:
# it wants keyrings, timers and a working DNS path, and it fails loudly and
# specifically when the kernel is too small.  strace (next stage) is how you
# find out which one.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VER//./_}/expat-$EXPAT_VER.tar.xz")
srcdir=$(extract "$tarball")
build_autotools expat "$srcdir" --prefix=/usr --disable-static --without-examples --without-tests
[[ -e "$LFN/usr/lib/libexpat.so.1" ]] || die "libexpat.so.1 missing"

tarball=$(fetch "https://curl.se/download/curl-$CURL_VER.tar.xz")
srcdir=$(extract "$tarball")
build_autotools curl "$srcdir" \
  --prefix=/usr \
  --with-openssl \
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
  --with-zlib \
  --without-libpsl \
  --without-libidn2 \
  --without-nghttp2 \
  --without-brotli \
  --without-zstd \
  --without-librtmp \
  --disable-ldap \
  --disable-ldaps \
  --enable-threaded-resolver

[[ -x "$LFN/usr/bin/curl" ]] || die "curl did not install"
check_links /usr/bin/curl || die "curl has unsatisfied dependencies"
step "guest curl: $(guest_run /usr/bin/curl --version | head -1)"
ok "expat $EXPAT_VER and curl $CURL_VER installed"
