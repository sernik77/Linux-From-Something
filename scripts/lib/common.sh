#!/usr/bin/env bash
# common.sh — shared helpers for every LFN build stage.
#
# The whole build runs as an unprivileged user.  Two things make that possible:
#   * fakeroot  — so `make install` can chown/chmod and the resulting tree
#                 really is owned by root:root inside the image;
#   * mke2fs -d — so the filesystem image is populated from a directory
#                 instead of being mounted (mount/losetup/qemu-nbd need root).

set -euo pipefail
shopt -s nullglob

# --------------------------------------------------------------- messaging ---
_c_reset=$'\033[0m'; _c_blue=$'\033[1;34m'; _c_green=$'\033[1;32m'
_c_yellow=$'\033[1;33m'; _c_red=$'\033[1;31m'; _c_dim=$'\033[2m'
[[ -t 2 ]] || { _c_reset=; _c_blue=; _c_green=; _c_yellow=; _c_red=; _c_dim=; }

# All of these go to stderr on purpose.  Helpers like fetch() and git_src()
# return a path by printing it, and a stray progress line on stdout would be
# captured into the caller's variable instead of shown.  The driver merges
# stderr into the stage log, so nothing is lost.
msg()  { printf '%s==>%s %s\n'   "$_c_blue"   "$_c_reset" "$*" >&2; }
ok()   { printf '%s ok %s %s\n'  "$_c_green"  "$_c_reset" "$*" >&2; }
warn() { printf '%s !! %s %s\n'  "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n'  "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }
step() { printf '%s  ->%s %s\n'  "$_c_dim"    "$_c_reset" "$*" >&2; }

# ------------------------------------------------------------------ stamps ---
# A stage is skipped when its stamp exists.  `./lfn redo <stage>` clears one.
stamped()   { [[ -f "$STAMPS/$1" ]]; }
set_stamp() { mkdir -p "$STAMPS"; date -Iseconds > "$STAMPS/$1"; }
clear_stamp() { rm -f "$STAMPS/$1"; }

# ---------------------------------------------------------------- fakeroot ---
# One persistent fakeroot state database is shared by every install step and by
# image creation, so ownership recorded during `make install` is still visible
# when mke2fs walks the tree.
#
# The database is keyed by (dev,ino) and never garbage-collects.  $BUILD is
# rm -rf'd and recreated constantly across stages (and stage retries), so its
# freed inodes get reused, and a fresh directory can inherit a stale fake
# entry — observed as `make install` misreporting a just-built subdirectory
# (e.g. ncurses' "man") as not-a-directory.  $LFN is the only tree whose
# ownership must survive between stages, so before the first frun() call in
# a stage, drop every recorded inode that isn't currently live under $LFN or
# whose inode has since been reused for a different kind of filesystem object.
fakeroot_prune() {
  local st="$FAKEROOT_STATE"
  [[ -f $st ]] || return 0
  local live="$st.live"
  find "$LFN" -printf '%i %y\n' | sort -un > "$live"
  awk -F'[=,]' '
    NR == FNR { split($1, f, " "); live[f[1]] = f[2]; next }
    function type(mode) {
      if (mode ~ /^100/) return "f"
      if (mode ~ /^40/)  return "d"
      if (mode ~ /^120/) return "l"
      if (mode ~ /^20/)  return "c"
      if (mode ~ /^60/)  return "b"
      if (mode ~ /^10/)  return "p"
      if (mode ~ /^140/) return "s"
      return "?"
    }
    ($4 in live) && live[$4] == type($6)
  ' "$live" "$st" > "$st.tmp"
  mv "$st.tmp" "$st"
  rm -f "$live"
}

frun() {
  local st="$FAKEROOT_STATE"
  [[ -n ${_FAKEROOT_PRUNED:-} ]] || { fakeroot_prune; _FAKEROOT_PRUNED=1; }
  if [[ -f $st ]]; then
    fakeroot -i "$st" -s "$st" -- "$@"
  else
    fakeroot -s "$st" -- "$@"
  fi
}

# ------------------------------------------------------------------ probes ---
# `ldd --version | head -1` looks harmless but dies under `set -o pipefail`:
# head closes the pipe, ldd takes SIGPIPE, and the whole stage aborts.  One
# sed, no pipeline.
host_glibc_version() {
  ldd --version 2>/dev/null | sed -n '1s/.*[^0-9.]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# ------------------------------------------------------------------- disk ----
free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
require_space() {
  local need=${1:-$MIN_FREE_GB} have
  have=$(free_gb "$LFN_WORK")
  (( have >= need )) || die "only ${have}G free under $LFN_WORK, need ${need}G"
}

# ------------------------------------------------------------------ fetch ----
# Downloads are resumable and verified by size>0; a partial file is retried.
fetch() {
  local url=$1 out=${2:-}
  [[ -n $out ]] || out=${url##*/}
  local dest="$SOURCES/$out"
  mkdir -p "$SOURCES"
  if [[ -s $dest ]]; then step "have $out"; printf '%s\n' "$dest"; return 0; fi
  step "fetch $url"
  curl -fL --retry 3 --retry-delay 2 -C - -o "$dest.part" "$url" >&2 \
    || die "download failed: $url"
  mv "$dest.part" "$dest"
  printf '%s\n' "$dest"
}

# Unpacks $1 into $SRC and echoes the resulting directory.  Idempotent.
extract() {
  local tarball=$1 dir=${2:-}
  mkdir -p "$SRC"
  if [[ -z $dir ]]; then
    # awk reads the whole listing rather than exiting on the first line: an
    # early exit closes the pipe, tar takes SIGPIPE, and pipefail turns that
    # into a stage failure.
    dir=$(tar -tf "$tarball" | awk -F/ 'NR==1{d=$1} END{print d}')
  fi
  if [[ -d "$SRC/$dir" && -n $(ls -A "$SRC/$dir" 2>/dev/null) ]]; then
    step "unpacked $dir"
  else
    step "extract ${tarball##*/}"
    tar -xf "$tarball" -C "$SRC"
  fi
  printf '%s\n' "$SRC/$dir"
}

# Shallow clone, or fast-forward an existing one.
git_src() {
  local url=$1 dir=$2 ref=${3:-master}
  mkdir -p "$SRC"
  if [[ -d "$SRC/$dir/.git" ]]; then
    step "have git $dir"
  else
    step "clone $url ($ref)"
    git clone -q --depth 1 --branch "$ref" "$url" "$SRC/$dir" >&2 \
      || git clone -q --depth 1 "$url" "$SRC/$dir" >&2
  fi
  printf '%s\n' "$SRC/$dir"
}

# ------------------------------------------------------------------ build ----
# The 90% case: out-of-tree configure && make && fakeroot make install.
# Usage: build_autotools <name> <srcdir> [configure args...]
build_autotools() {
  local name=$1 srcdir=$2; shift 2
  local bdir="$BUILD/$name"
  rm -rf "$bdir"; mkdir -p "$bdir"
  step "configure $name"
  ( cd "$bdir" && "$srcdir/configure" "$@" ) \
    || die "$name: configure failed"
  step "make $name (-j$JOBS)"
  make -C "$bdir" -j"$JOBS" || die "$name: build failed"
  step "install $name -> \$LFN"
  frun make -C "$bdir" install DESTDIR="$LFN" || die "$name: install failed"
  sanitize_tree
  drop_build "$bdir"
}

# Cross-building leaves host paths behind in the guest tree: pkg-config files
# and libtool archives faithfully record the -L/-I flags they were built with,
# which here point at $LFN on the *host*.  Inside the guest those paths do not
# exist, so a later in-guest build would silently lose its library search path.
# Strip them; /usr/lib and /usr/include are correct from the guest's side.
sanitize_tree() {
  local f
  while IFS= read -r -d '' f; do
    grep -q -- "$LFN" "$f" 2>/dev/null || continue
    sed -i -e "s|-L$LFN/usr/lib||g" \
           -e "s|-I$LFN/usr/include||g" \
           -e "s|-Wl,-rpath-link,$LFN/usr/lib||g" \
           -e "s|$LFN||g" \
           -e 's/  */ /g' "$f"
  done < <(find "$LFN/usr/lib" "$LFN/usr/share" -type f \
             \( -name '*.pc' -o -name '*.la' \) -print0)
}

drop_build() {
  [[ ${KEEP_BUILD_DIRS:-0} == 1 ]] || rm -rf "$1"
}

# ------------------------------------------------------- runtime link check ---
# The single most valuable gate in this whole build: run a guest binary on the
# host through the *guest* dynamic loader, restricted to the *guest* library
# path.  If that works, the binary will work inside the VM; if it does not, no
# amount of QEMU debugging will help.
GUEST_LD=""
guest_loader() {
  [[ -n $GUEST_LD ]] && { printf '%s\n' "$GUEST_LD"; return; }
  local c
  for c in "$LFN/usr/lib/ld-linux-x86-64.so.2" "$LFN/lib64/ld-linux-x86-64.so.2"; do
    [[ -x $c ]] && { GUEST_LD=$c; printf '%s\n' "$c"; return; }
  done
  die "guest dynamic loader not found (glibc not installed yet?)"
}

# guest_run <guest-path> [args...]   e.g. guest_run /usr/bin/zsh -c 'echo hi'
guest_run() {
  local bin=$1; shift
  local ld; ld=$(guest_loader)
  "$ld" --library-path "$LFN/usr/lib" "$LFN$bin" "$@"
}

# Walks the installed tree and reports any ELF object whose DT_NEEDED entries
# or ELF interpreter cannot be satisfied from inside the tree itself.
#
# This resolves by hand rather than asking ld.so, on purpose: even with
# --library-path the loader still falls back to the host's /usr/lib, which
# would happily satisfy a dependency that is missing from the guest and hide
# exactly the bug we are looking for.
check_links() {
  local scope=${1:-}
  local -a targets=()
  local -A available=()
  local candidate
  while IFS= read -r -d '' candidate; do
    available["${candidate##*/}"]=1
  done < <(find "$LFN/usr/lib" \( -type f -o -type l \) -print0 2>/dev/null)
  if [[ -n $scope ]]; then
    targets=("$LFN$scope")
  else
    # Include compiler internals and language extension modules in nested
    # directories.  A flat /usr/lib/*.so* scan missed GCC's cc1/lto1 and
    # Perl's auto/* modules, allowing host dependencies through until boot.
    mapfile -d '' targets < <(
      find "$LFN/usr/bin" "$LFN/usr/sbin" "$LFN/usr/lib" \
        -type f -print0 2>/dev/null
    )
  fi
  local missing=0 f
  for f in "${targets[@]}"; do
    [[ -f $f && ! -L $f ]] || continue
    [[ $(head -c4 "$f" 2>/dev/null) == $'\x7fELF' ]] || continue
    local interp need lib
    interp=$(readelf -lW "$f" 2>/dev/null | grep -oE 'interpreter: [^]]+' | cut -d' ' -f2 || true)
    if [[ -n $interp && ! -e "$LFN$interp" ]]; then
      warn "${f#$LFN}: interpreter $interp missing from tree"; missing=1
    fi
    need=$(readelf -dW "$f" 2>/dev/null | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[\(.*\)\]/\1/' || true)
    for lib in $need; do
      if [[ -z ${available[$lib]:-} ]]; then
        warn "${f#$LFN}: needs $lib — not in tree"; missing=1
      fi
    done
  done
  (( missing == 0 )) || return 1
  return 0
}

# Compile and link userland against the *guest* tree, not the host's /usr.
# Without this, configure happily finds host ncurses/zlib/openssl and records
# a DT_NEEDED the guest cannot satisfy (or, worse, one whose symbols live in a
# differently-split library on the host).
use_guest_flags() {
  # The guest headers are the system headers for these builds, but they must
  # not shadow a package's own private headers.  In particular, binutils ships
  # include/obstack.h for libiberty; putting $LFN/usr/include first with -I
  # made the compiler pick glibc's public obstack.h instead and left
  # _OBSTACK_SIZE_T undefined.  -isystem still places the guest tree ahead of
  # the host's default /usr/include while preserving every package-local -I.
  export CPPFLAGS="-isystem $LFN/usr/include ${CPPFLAGS_EXTRA:-}"
  export LDFLAGS="-L$LFN/usr/lib -Wl,-rpath-link,$LFN/usr/lib ${LDFLAGS_EXTRA:-}"
  # Release tarballs contain generated scanners; no target program needs the
  # host's flex runtime.  Marking LEXLIB as explicitly empty also prevents old
  # autoconf probes from adding -lfl to unrelated programs such as ar/ranlib.
  export LEXLIB=
  export PKG_CONFIG_LIBDIR="$LFN/usr/lib/pkgconfig:$LFN/usr/share/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR="$LFN"
}

# ------------------------------------------------------------------ misc -----
# GNU tarballs of this era need a working makeinfo for some targets; the host
# has no texinfo, and every affected package treats it as optional if told so.
export MAKEINFO=true
export HELP2MAN=true

# Keep configure scripts from picking up host oddities.  TERMINFO in
# particular: terminal emulators such as kitty export it, and ncurses then
# helpfully installs its whole terminfo database into the emulator's private
# directory inside DESTDIR, where nothing in the guest will ever look.
export LC_ALL=C
unset TERMINFO TERMINFO_DIRS TERMCAP CDPATH
export TERM=dumb
