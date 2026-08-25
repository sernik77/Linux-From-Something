#!/usr/bin/env bash
# Phase 2.2a — OpenSSL, plus the CA bundle that makes TLS verification work.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz")
srcdir=$(extract "$tarball")

# OpenSSL's Configure insists on building in the source tree.
bdir="$BUILD/openssl"
rm -rf "$bdir"; cp -a "$srcdir" "$bdir"; cd "$bdir"

step "Configure openssl $OPENSSL_VER"
./Configure linux-x86_64 \
  --prefix=/usr \
  --openssldir=/etc/ssl \
  --libdir=lib \
  shared \
  no-tests \
  zlib \
  -Wl,-rpath-link,"$LFN/usr/lib" \
  || die "openssl Configure failed"

make -j"$JOBS" || die "openssl build failed"
# install_sw skips the (large, useless here) man pages; install_ssldirs lays
# out /etc/ssl.
frun make install_sw install_ssldirs DESTDIR="$LFN" || die "openssl install failed"

for f in usr/lib/libssl.so.3 usr/lib/libcrypto.so.3 usr/bin/openssl; do
  [[ -e "$LFN/$f" ]] || die "openssl install incomplete: /$f"
done
check_links /usr/bin/openssl || die "openssl has unsatisfied dependencies"

# ---------------------------------------------------------- CA certificates --
# Without these, every https:// fetch inside the guest fails verification.
# This is Mozilla's root store as published by the curl project.
step "installing Mozilla CA bundle"
ca=$(fetch "https://curl.se/ca/cacert.pem" "cacert.pem")
install -Dm644 "$ca" "$LFN/etc/ssl/certs/ca-certificates.crt"
ln -sfn ca-certificates.crt "$LFN/etc/ssl/cert.pem"

# Tools disagree about where to look; point all of them at the one bundle.
install -Dm755 /dev/stdin "$LFN/etc/init.d/05-ssl-env" <<'EOF'
#!/bin/zsh
# Exported by init for every later service; the interactive shell picks the
# same values up from /etc/zsh/zshenv.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs
EOF

cat >> "$LFN/etc/zsh/zshenv" <<'EOF'

# TLS trust store (installed with OpenSSL in Phase 2).
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
EOF

step "guest openssl: $(guest_run /usr/bin/openssl version)"
step "CA bundle: $(grep -c 'BEGIN CERTIFICATE' "$LFN/etc/ssl/certs/ca-certificates.crt") roots"

drop_build "$bdir"
ok "openssl $OPENSSL_VER installed with CA trust store"
