#!/usr/bin/env bash
# Phase 1.1a — fetch the kernel tree and install its userspace headers.
#
# glibc has to be compiled against the headers of the kernel it will run on,
# so the tree is cloned before anything else is built.  The kernel image
# itself is built much later (stage 50), once we know what userland needs.
source "$LFN_PROJ/scripts/lib/prologue.sh"

kdir=$(git_src "$KERNEL_GIT" linux "$KERNEL_REF")
cd "$kdir"

rel=$(make -s kernelversion)
step "kernel $rel ($(git rev-parse --short HEAD))"

step "headers_install -> \$LFN/usr/include"
# headers_install generates include/generated and host helper artefacts.  Keep
# those out of the source checkout: stage 50 uses an O= build and Kbuild
# refuses to start one while in-tree output from this earlier stage exists.
make -s mrproper
hbuild="$BUILD/linux-headers"
rm -rf "$hbuild"; mkdir -p "$hbuild"
make -s O="$hbuild" headers_install INSTALL_HDR_PATH="$LFN/usr" ARCH=x86
drop_build "$hbuild"

# Sanity: the three headers glibc's configure explicitly probes for.
for h in linux/version.h asm/unistd.h asm-generic/unistd.h; do
  [[ -f "$LFN/usr/include/$h" ]] || die "missing installed header $h"
done

printf '%s\n' "$rel" > "$LFN_WORK/.kernel-version"
ok "kernel headers for $rel installed ($(find "$LFN/usr/include" -name '*.h' | wc -l) files)"
