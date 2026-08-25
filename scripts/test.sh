#!/usr/bin/env bash
# Run the automated boot tests.  Each test is an expect script under tests/;
# `./lfn test` runs them all, `./lfn test 01-boot` runs one.
source "$LFN_PROJ/scripts/lib/prologue.sh"

testdir="$LFN_PROJ/tests"
mode=direct
declare -a want=()
echo_output=0

while (($#)); do
  case $1 in
    --disk) mode=disk ;;
    --echo) echo_output=1 ;;
    *) want+=("$1") ;;
  esac
  shift
done

if ((${#want[@]} == 0)); then
  mapfile -t tests < <(printf '%s\n' "$testdir"/*.expect | sort)
else
  tests=()
  for w in "${want[@]}"; do
    if [[ -f "$testdir/$w.expect" ]]; then tests+=("$testdir/$w.expect")
    elif [[ -f $w ]]; then tests+=("$w")
    else die "no such test: $w"; fi
  done
fi

accel=(-machine q35,accel=kvm:tcg -cpu host)
[[ -w /dev/kvm ]] || accel=(-machine q35 -cpu max)

qemu_base=(
  qemu-system-x86_64
  "${accel[@]}"
  -m "$QEMU_MEM" -smp "$QEMU_SMP"
  -netdev "user,id=net0,hostfwd=tcp::$QEMU_SSH_PORT-:22"
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci
  -no-reboot -display none -serial stdio -monitor none
)

case $mode in
  direct)
    [[ -f $OUT/bzImage && -f $OUT/rootfs.ext4 ]] || die "build the kernel and image first"
    qemu_base+=(
      -kernel "$OUT/bzImage"
      -drive "file=$OUT/rootfs.ext4,format=raw,if=virtio,cache=writeback"
      -append "root=/dev/vda rw rootfstype=ext4 rootwait console=ttyS0,115200 panic=5"
    )
    ;;
  disk)
    [[ -f $OUT/disk.img ]] || die "no bootable disk image"
    qemu_base+=( -drive "file=$OUT/disk.img,format=raw,if=virtio,cache=writeback" )
    ;;
esac

pass=0; fail=0; failed=()
for t in "${tests[@]}"; do
  name=$(basename "$t" .expect)
  msg "test $name ($mode)"
  logf="$LOGS/test-$name.serial.log"
  args=(--script "$t" --timeout 120 --log "$logf")
  ((echo_output)) && args+=(--echo)
  # A fresh copy of the disk per test: tests are allowed to write.
  if [[ $mode == direct ]]; then
    source_img="$OUT/rootfs.ext4"
  else
    source_img="$OUT/disk.img"
  fi
  work_img="$OUT/.test-$name-$mode.img"
  cp --reflink=auto "$source_img" "$work_img"
  declare -a qemu=("${qemu_base[@]}")
  for i in "${!qemu[@]}"; do
    [[ ${qemu[$i]} == file=$source_img* ]] && qemu[$i]=${qemu[$i]/$source_img/$work_img}
  done
  if python3 "$LFN_PROJ/scripts/lib/qemu_expect.py" "${args[@]}" -- "${qemu[@]}"; then
    ok "$name passed  (serial log: ${logf#$LFN_WORK/})"
    ((++pass))
  else
    warn "$name FAILED (serial log: ${logf#$LFN_WORK/})"
    failed+=("$name"); ((++fail))
  fi
  rm -f "$work_img"
done

echo
if ((fail)); then
  die "$pass passed, $fail failed: ${failed[*]}"
fi
ok "all $pass tests passed"
