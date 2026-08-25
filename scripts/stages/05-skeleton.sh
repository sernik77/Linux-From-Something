#!/usr/bin/env bash
# Phase 0 — the merged-/usr root skeleton, Arch style.
#
#   /bin  /sbin        -> usr/bin      (one binary directory, like Arch)
#   /lib  /lib64       -> usr/lib      (one library directory)
#   /usr/sbin          -> bin
#   /usr/lib64         -> lib
#
# The lib64 symlink matters more than it looks: every binary the host compiler
# produces asks for /lib64/ld-linux-x86-64.so.2, while glibc is configured to
# install its loader into /usr/lib.  The symlink is what makes those meet.
source "$LFN_PROJ/scripts/lib/prologue.sh"

mkdir -p "$LFN"
cd "$LFN"

mkdir -p usr/{bin,lib,include,share,libexec,local} \
         usr/share/{man,doc,terminfo,misc} \
         etc/{zsh,ssl,skel} \
         var/{log,tmp,lib,cache,spool} \
         root boot dev proc sys run tmp mnt home srv opt

ln -sfn bin usr/sbin
ln -sfn lib usr/lib64

ln -sfn usr/bin  bin
ln -sfn usr/bin  sbin
ln -sfn usr/lib  lib
ln -sfn usr/lib  lib64
ln -sfn ../run   var/run
ln -sfn ../run/lock var/lock

chmod 1777 tmp var/tmp
chmod 700 root

# proc, sys, dev stay empty — the kernel and init populate them.
for d in proc sys dev run; do [[ -d $d ]] || mkdir -p "$d"; done

step "layout:"
ls -l "$LFN" | sed 's/^/       /'
ok "skeleton ready at $LFN"
