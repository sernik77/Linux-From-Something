#!/usr/bin/env bash
# Boot the guest.  Two ways in:
#
#   --direct (default)  QEMU loads bzImage itself; no bootloader involved.
#                       This is what makes the whole build root-free.
#   --disk              boot the partitioned disk through the GRUB we build
#                       from source in Phase 5, exactly like real hardware.
#
# Leave the guest with `poweroff`, or Ctrl-A X.
source "$LFN_PROJ/scripts/lib/prologue.sh"

mode=direct
extra_append=""
declare -a extra_qemu=()

while (($#)); do
  case $1 in
    --direct) mode=direct ;;
    --disk)   mode=disk ;;
    --rescue) extra_append+=" init=/bin/zsh" ;;
    --debug)  extra_append+=" earlyprintk=serial,ttyS0 ignore_loglevel" ;;
    --append) shift; extra_append+=" $1" ;;
    --)       shift; extra_qemu+=("$@"); break ;;
    *)        extra_qemu+=("$1") ;;
  esac
  shift
done

accel=(-machine q35,accel=kvm:tcg -cpu host)
[[ -w /dev/kvm ]] || { warn "no KVM access — falling back to TCG emulation"; accel=(-machine q35 -cpu max); }

qemu=(
  qemu-system-x86_64
  "${accel[@]}"
  -m "$QEMU_MEM" -smp "$QEMU_SMP"
  -netdev "user,id=net0,hostfwd=tcp::$QEMU_SSH_PORT-:22"
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci
  -no-reboot
  -display none
  -serial mon:stdio
)

case $mode in
  direct)
    [[ -f $OUT/bzImage ]]      || die "no kernel at $OUT/bzImage — run ./lfn build"
    [[ -f $OUT/rootfs.ext4 ]]  || die "no image at $OUT/rootfs.ext4 — run ./lfn build"
    qemu+=(
      -kernel "$OUT/bzImage"
      -drive "file=$OUT/rootfs.ext4,format=raw,if=virtio,cache=writeback"
      -append "root=/dev/vda rw rootfstype=ext4 rootwait console=ttyS0,115200 panic=10$extra_append"
    )
    ;;
  disk)
    [[ -f $OUT/disk.img ]] || die "no bootable disk at $OUT/disk.img — run ./lfn build 90-grub"
    qemu+=( -drive "file=$OUT/disk.img,format=raw,if=virtio,cache=writeback" )
    ;;
esac

msg "booting LFN ($mode mode)"
step "${qemu[*]}"
exec "${qemu[@]}" "${extra_qemu[@]}"
