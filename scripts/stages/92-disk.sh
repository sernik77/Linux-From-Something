#!/usr/bin/env bash
# Phase 5.2 — a partitioned, self-booting disk image.
#
# Same result as the doc's `fdisk` + `mkfs.ext4` + `grub-install` sequence,
# minus every step that needs root:
#   sfdisk           writes the MBR partition table into a plain file
#   mke2fs -E offset  makes the filesystem *inside* that partition
#   grub-bios-setup   writes boot.img to sector 0 and embeds core.img in the
#                     post-MBR gap, again straight into the file
source "$LFN_PROJ/scripts/lib/prologue.sh"

hostdir="$LFN_WORK/grub-host"
[[ -x "$hostdir/sbin/grub-bios-setup" ]] || die "grub tools missing — run stage 90 first"
[[ -f "$LFN/boot/bzImage" ]] || die "no kernel in the tree — run stage 50 first"
[[ -d "$LFN/boot/grub/i386-pc" ]] || die "no grub modules in the tree — run stage 90"

img="$OUT/disk.img"
part_offset=1048576                       # 1 MiB — sector 2048, the usual place
total_mb=$(( IMAGE_SIZE_MB + 2 ))

step "recording root ownership"
frun chown -R 0:0 "$LFN"

step "creating ${total_mb}M raw disk"
rm -f "$img"
truncate -s "${total_mb}M" "$img"

step "partition table"
sfdisk --quiet "$img" <<EOF
label: dos
unit: sectors
start=2048, type=83, bootable
EOF

# mke2fs writes the filesystem at the partition offset; the size is given in
# 1K blocks so the filesystem stops exactly at the end of the disk.
step "mke2fs inside partition 1"
frun mke2fs -q -t ext4 -L "$IMAGE_LABEL" \
     -O ^metadata_csum_seed,^orphan_file \
     -E "offset=$part_offset,root_owner=0:0" \
     -d "$LFN" "$img" "$(( IMAGE_SIZE_MB * 1024 ))" \
  || die "mke2fs failed"

# ------------------------------------------------------------- bootloader ----
core="$hostdir/lib/grub/i386-pc/lfn-core.img"
step "grub-mkimage (biosdisk part_msdos ext2 …)"
"$hostdir/bin/grub-mkimage" \
  -O i386-pc \
  -d "$hostdir/lib/grub/i386-pc" \
  -p '(hd0,msdos1)/boot/grub' \
  -o "$core" \
  biosdisk part_msdos ext2 normal linux configfile echo search search_fs_uuid \
  search_label serial terminal loadenv \
  || die "grub-mkimage failed"

step "grub-bios-setup -> MBR + embedding area"
device_map="$BUILD/device.map"
install -Dm644 /dev/stdin "$device_map" <<EOF
(hd0) $img
EOF
"$hostdir/sbin/grub-bios-setup" \
  --directory="$hostdir/lib/grub/i386-pc" \
  --boot-image=boot.img \
  --core-image="$(basename "$core")" \
  --device-map="$device_map" \
  --skip-fs-probe \
  '(hd0)' 2>&1 | sed 's/^/       /' >&2 || die "grub-bios-setup failed"

# ---------------------------------------------------------------- verify -----
step "verifying"
[[ $(dd if="$img" bs=1 skip=510 count=2 2>/dev/null | xxd -p) == 55aa ]] \
  || die "no boot signature in the MBR"
sfdisk -l "$img" 2>/dev/null | sed 's/^/       /' >&2
debugfs -R "stat /boot/bzImage" "$img?offset=$part_offset" >/dev/null 2>&1 \
  || warn "could not stat /boot/bzImage through debugfs (offset syntax); check manually"

sync
ok "bootable disk image ready: $img  (boot it with ./lfn boot --disk)"
