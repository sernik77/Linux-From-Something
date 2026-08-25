#!/usr/bin/env bash
# Phase 0 — verify the Arch host can actually do this build.
source "$LFN_PROJ/scripts/lib/prologue.sh"

fail=0
# Deliberately does not execute the tool: several of these (bzip2, gzip) read
# stdin when handed an unexpected argument, which hangs or garbles the log.
need() {
  if command -v "$1" >/dev/null; then step "$(printf '%-18s %s' "$1" "$(command -v "$1")")"
  else warn "missing required tool: $1"; fail=1; fi
}
opt() {
  command -v "$1" >/dev/null || warn "optional tool absent: $1 ($2)"
}

msg "required host tools"
for t in gcc g++ make ld ar git curl tar xz gzip bzip2 patch sed gawk perl \
         python3 bison flex bc rsync cpio fakeroot mke2fs sfdisk \
         qemu-system-x86_64 qemu-img readelf pkg-config; do
  need "$t"
done

msg "optional host tools"
opt pahole "only needed if you enable CONFIG_DEBUG_INFO_BTF"
opt makeinfo "GNU docs; the build sets MAKEINFO=true to skip them"
opt grub-mkimage "needed only for the Phase 5 BIOS bootloader stage"

msg "kernel virtualisation"
if [[ -w /dev/kvm ]]; then ok "/dev/kvm writable — KVM acceleration available"
else warn "/dev/kvm not writable; QEMU will fall back to TCG (much slower)"; fi

msg "host toolchain vs. guest glibc"
host_glibc=$(host_glibc_version)
step "host glibc $host_glibc / guest glibc $GLIBC_VER"
if [[ $host_glibc != "$GLIBC_VER" ]]; then
  warn "guest glibc differs from the host's."
  warn "Phase 1-3 binaries are produced by the host compiler and linked against"
  warn "host headers, so a guest libc older than $host_glibc will fail at boot"
  warn "with 'version GLIBC_x.yz not found'. Set GLIBC_VER=$host_glibc unless"
  warn "you know exactly why you want a different one."
fi

msg "disk"
avail=$(free_gb "$LFN_WORK")
step "${avail}G free under $LFN_WORK"
(( avail >= MIN_FREE_GB )) || { warn "less than ${MIN_FREE_GB}G free"; fail=1; }

msg "layout"
step "work dir  $LFN_WORK"
step "root tree $LFN"
step "jobs      -j$JOBS"

(( fail == 0 )) || die "host is not ready — install what is missing and re-run"
ok "host is ready"
