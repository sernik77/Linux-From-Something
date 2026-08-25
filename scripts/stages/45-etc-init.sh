#!/usr/bin/env bash
# Phase 1.8 — /etc and the init program.
#
# init is PID 1: if it exits, the kernel panics.  So every single step here is
# non-fatal and the shell is exec'd unconditionally at the end.  A system that
# boots to a shell with three failed mounts can be repaired from inside; one
# that panics during init cannot.
source "$LFN_PROJ/scripts/lib/prologue.sh"

# ----------------------------------------------------------------- /etc -----
install -Dm644 /dev/stdin "$LFN/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/zsh
nobody:x:65534:65534:nobody:/:/usr/bin/false
EOF

install -Dm644 /dev/stdin "$LFN/etc/group" <<'EOF'
root:x:0:
tty:x:5:
disk:x:6:
kmem:x:9:
wheel:x:10:
nobody:x:65534:
EOF

install -Dm640 /dev/stdin "$LFN/etc/shadow" <<'EOF'
root::19000:0:99999:7:::
EOF

install -Dm644 /dev/stdin "$LFN/etc/hostname" <<'EOF'
lfn
EOF

install -Dm644 /dev/stdin "$LFN/etc/hosts" <<'EOF'
127.0.0.1   localhost lfn
::1         localhost
EOF

# glibc's NSS is quietly useless without this file: getpwnam(), gethostbyname()
# and friends fall back to nothing and the shell cannot even resolve uid 0.
install -Dm644 /dev/stdin "$LFN/etc/nsswitch.conf" <<'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

install -Dm644 /dev/stdin "$LFN/etc/ld.so.conf" <<'EOF'
/usr/lib
/usr/local/lib
EOF

install -Dm644 /dev/stdin "$LFN/etc/resolv.conf" <<'EOF'
# QEMU user-mode networking runs a DNS forwarder on .3 of the guest network.
nameserver 10.0.2.3
nameserver 1.1.1.1
EOF

install -Dm644 /dev/stdin "$LFN/etc/fstab" <<'EOF'
# <device>   <mount>  <type>      <options>          <dump> <pass>
/dev/vda     /        ext4        rw,relatime         0      1
proc         /proc    proc        nosuid,noexec,nodev 0      0
sysfs        /sys     sysfs       nosuid,noexec,nodev 0      0
devtmpfs     /dev     devtmpfs    mode=0755,nosuid    0      0
devpts       /dev/pts devpts      gid=5,mode=620      0      0
tmpfs        /run     tmpfs       nosuid,nodev,mode=755 0    0
tmpfs        /tmp     tmpfs       nosuid,nodev        0      0
EOF

install -Dm644 /dev/stdin "$LFN/etc/os-release" <<EOF
NAME="Linux From Nothing"
PRETTY_NAME="Linux From Nothing (Arch host edition)"
ID=lfn
BUILD_ID=$(date +%Y%m%d)
ANSI_COLOR="0;36"
EOF

install -Dm644 /dev/stdin "$LFN/etc/shells" <<'EOF'
/bin/sh
/bin/zsh
/usr/bin/zsh
EOF

install -Dm644 /dev/stdin "$LFN/etc/issue" <<'EOF'
Linux From Nothing \r on \l

EOF

# ------------------------------------------------------------- zsh setup ----
install -Dm644 /dev/stdin "$LFN/etc/zsh/zshenv" <<'EOF'
# System-wide zsh environment.  Kept deliberately small.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LANG=C
export LC_ALL=C
EOF

install -Dm644 /dev/stdin "$LFN/etc/zsh/zshrc" <<'EOF'
# Interactive shell defaults for LFN.
setopt PROMPT_SUBST INTERACTIVE_COMMENTS NO_BEEP
setopt HIST_IGNORE_DUPS SHARE_HISTORY EXTENDED_HISTORY
HISTFILE=~/.zsh_history; HISTSIZE=5000; SAVEHIST=5000

autoload -Uz compinit 2>/dev/null && compinit -u -d ~/.zcompdump 2>/dev/null
zstyle ':completion:*' menu select

PROMPT='%F{cyan}lfn%f:%F{yellow}%~%f %(!.#.$) '
RPROMPT='%(?..%F{red}%?%f)'

alias ls='ls --color=auto -F'
alias ll='ls -lh'
alias la='ls -lha'
alias grep='grep --color=auto'
alias ..='cd ..'

# Where the guest builds its own software once the toolchain lands (Phase 3+).
export MAKEFLAGS="-j$(nproc 2>/dev/null || echo 2)"
EOF

install -Dm644 /dev/stdin "$LFN/root/.zshrc" <<'EOF'
[[ -r /etc/zsh/zshrc ]] && source /etc/zsh/zshrc
EOF

install -Dm644 /dev/stdin "$LFN/etc/profile" <<'EOF'
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LANG=C LC_ALL=C
export PS1='lfn:\w \$ '
EOF

# ----------------------------------------------------------------- init -----
install -Dm755 /dev/stdin "$LFN/usr/bin/init" <<'EOF'
#!/bin/zsh
#
# LFN init — PID 1.
#
# Rules this file lives by:
#   1. never exit; if it does, the kernel panics
#   2. every step is optional and non-fatal
#   3. print a sentinel the host test harness can grep for
#
# Rescue: append init=/bin/zsh to the kernel command line to skip all of this.

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/root
export TERM=${TERM:-linux}
export LANG=C LC_ALL=C
export SHELL=/bin/zsh

try() { "$@" 2>/dev/null || print -u2 "init: failed: $*" }

print "init: Linux From Nothing starting"

# --- virtual filesystems ----------------------------------------------------
try mount -t proc     proc     /proc
try mount -t sysfs    sys      /sys
# devtmpfs is normally mounted by the kernel (CONFIG_DEVTMPFS_MOUNT); this is
# only a fallback for kernels built without it.
mountpoint -q /dev 2>/dev/null || try mount -t devtmpfs dev /dev
[[ -d /dev/pts ]] || mkdir -p /dev/pts
try mount -t devpts   devpts   /dev/pts -o gid=5,mode=620
try mount -t tmpfs    tmpfs    /run  -o mode=755
try mount -t tmpfs    tmpfs    /tmp  -o mode=1777

# --- writable root ----------------------------------------------------------
try mount -o remount,rw /

# --- dynamic linker cache ---------------------------------------------------
# Generated here rather than on the host: `ldconfig -r` chroots, which an
# unprivileged host build cannot do.
if [[ ! -f /etc/ld.so.cache ]] && [[ -x /usr/bin/ldconfig ]]; then
    print "init: building /etc/ld.so.cache"
    try ldconfig
fi

# --- identity ---------------------------------------------------------------
[[ -r /etc/hostname ]] && try hostname "$(cat /etc/hostname)"

# --- network ----------------------------------------------------------------
# QEMU user-mode (SLIRP): gateway 10.0.2.2, DNS 10.0.2.3, guest 10.0.2.15.
if [[ -x /usr/bin/ip ]]; then
    try ip link set lo up
    for dev in eth0 ens3 enp0s2 enp0s3; do
        if ip link show $dev >/dev/null 2>&1; then
            print "init: configuring $dev"
            try ip link set $dev up
            try ip addr add 10.0.2.15/24 dev $dev
            try ip route add default via 10.0.2.2
            break
        fi
    done
elif [[ -x /usr/bin/ifconfig ]]; then
    try ifconfig lo up
fi

# --- local extensions -------------------------------------------------------
# Anything dropped into /etc/init.d runs here, in name order.  This is how
# later phases (dnsmasq, sshd, …) hook themselves in without editing init.
if [[ -d /etc/init.d ]]; then
    for s in /etc/init.d/*(N); do
        [[ -x $s ]] && { print "init: running ${s:t}"; try $s start }
    done
fi

# --- the sentinel the automated boot test looks for -------------------------
print "LFN-INIT-OK $(uname -r)"

print ""
[[ -r /etc/issue ]] && cat /etc/issue
print "Welcome to Linux From Nothing.  Type 'poweroff' or Ctrl-A X to leave."
print ""

cd /root
exec /bin/zsh -l
EOF

# The kernel looks for /sbin/init; /sbin is a symlink to usr/bin, so this is
# the same file.  Keep an explicit copy of the path in the tree for clarity.
ln -sfn init "$LFN/usr/bin/rc"

install -Dm755 /dev/stdin "$LFN/usr/bin/poweroff" <<'EOF'
#!/bin/zsh
# No ACPI daemon here: ask the kernel directly.
sync; sync; sync
print "Powering off."
if [[ -w /proc/sysrq-trigger ]]; then
    print o > /proc/sysrq-trigger
fi
# Fall back to util-linux if sysrq is not compiled in.
exec /usr/bin/halt -p -f 2>/dev/null || true
EOF

install -Dm755 /dev/stdin "$LFN/usr/bin/rebootnow" <<'EOF'
#!/bin/zsh
sync; sync; sync
print b > /proc/sysrq-trigger 2>/dev/null || exec /usr/bin/reboot -f
EOF

mkdir -p "$LFN/etc/init.d"

# ------------------------------------------------------------- verify -------
[[ -x "$LFN/usr/bin/init" ]] || die "init not installed"
[[ -e "$LFN/sbin/init" ]] || die "/sbin/init does not resolve (skeleton symlinks?)"
guest_run /usr/bin/zsh -n "$LFN/usr/bin/init" \
  || die "init has a zsh syntax error — it would panic the kernel"

ok "/etc populated and init installed (syntax-checked with the guest zsh)"
