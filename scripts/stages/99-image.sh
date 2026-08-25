#!/usr/bin/env bash
# Phase 1.9 — turn the root tree into a filesystem image.
#
# The doc mounts a qcow2 through qemu-nbd and copies files in as root.  That
# needs root three times over (modprobe, qemu-nbd, mount).  mke2fs -d builds
# the same filesystem straight from a directory, and fakeroot supplies the
# root:root ownership, so the whole thing runs unprivileged.
source "$LFN_PROJ/scripts/lib/prologue.sh"

[[ -d "$LFN/usr/bin" ]] || die "root tree is empty"
[[ -x "$LFN/usr/bin/init" ]] || die "no init in the tree — run stage 45"

# Everything in the image belongs to root.  Under fakeroot this only records
# ownership in the state database; no real file changes hands.
step "recording root ownership"
frun chown -R 0:0 "$LFN"

img="$OUT/rootfs.ext4"
rm -f "$img"

# ^metadata_csum_seed and ^orphan_file: GRUB's ext2 driver (Phase 5) does not
# understand either feature, and mke2fs 1.47 turns both on by default.
step "mke2fs ${IMAGE_SIZE_MB}M -> ${img#$LFN_WORK/}"
frun mke2fs -q -t ext4 -L "$IMAGE_LABEL" \
     -O ^metadata_csum_seed,^orphan_file \
     -E root_owner=0:0 \
     -d "$LFN" "$img" "${IMAGE_SIZE_MB}M" \
  || die "mke2fs failed"

# Verify the image really contains a bootable arrangement.
step "verifying image contents"
for p in sbin/init bin/zsh usr/lib/libc.so.6 usr/lib/ld-linux-x86-64.so.2 etc/passwd; do
  debugfs -R "stat /$p" "$img" >/dev/null 2>&1 || die "image lacks /$p"
done
used=$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/Free blocks/{f=$2} /Block count/{t=$2} END{printf "%d", (t-f)*100/t}')
step "filesystem ${used}% used, label $(dumpe2fs -h "$img" 2>/dev/null | awk -F': +' '/Filesystem volume name/{print $2}')"

sync
ok "root filesystem image ready: $img"
