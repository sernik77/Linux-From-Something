#!/usr/bin/env bash
# Phase 2.2b — pcre2 and wget: the guest can now pull its own sources.
#
# This is the point where LFN stops being a thing you feed from the host and
# starts being a system that can go and get its own next package.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

# ----------------------------------------------------------------- pcre2 ----
tarball=$(fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.bz2")
srcdir=$(extract "$tarball")
build_autotools pcre2 "$srcdir" \
  --prefix=/usr \
  --enable-unicode \
  --enable-pcre2-16 \
  --enable-pcre2-32 \
  --disable-static
[[ -e "$LFN/usr/lib/libpcre2-8.so.0" ]] || die "libpcre2-8 missing"

# ------------------------------------------------------------------ wget ----
# --without-libpsl: the public-suffix list is a cookie-policy nicety and its
# library is not in the guest.  --disable-iri: needs libidn2, same story.
# Wget's gnulib still probes libunistring for non-IRI helpers; force its bundled
# subset so a host libunistring cannot leak into the guest's DT_NEEDED list.
tarball=$(fetch "https://ftp.gnu.org/gnu/wget/wget-$WGET_VER.tar.gz")
srcdir=$(extract "$tarball")
build_autotools wget "$srcdir" \
  --prefix=/usr \
  --sysconfdir=/etc \
  --disable-nls \
  --disable-iri \
  --with-ssl=openssl \
  --with-openssl=yes \
  --with-included-libunistring \
  --without-libpsl \
  --without-libuuid

[[ -x "$LFN/usr/bin/wget" ]] || die "wget did not install"
check_links /usr/bin/wget || die "wget has unsatisfied dependencies"

install -Dm644 /dev/stdin "$LFN/etc/wgetrc" <<'EOF'
# LFN defaults: verify TLS against the bundle installed with OpenSSL.
ca_certificate = /etc/ssl/certs/ca-certificates.crt
check_certificate = on
timeout = 30
tries = 3
EOF

step "guest wget: $(guest_run /usr/bin/wget --version | head -1)"
ok "pcre2 $PCRE2_VER and wget $WGET_VER installed"
