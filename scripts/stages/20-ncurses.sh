#!/usr/bin/env bash
# Phase 1.7 — ncurses, wide and non-wide.
#
# Both are needed: everything modern links the wide (…w) libraries, but the
# kernel's own menuconfig, built later *inside* LFN, still wants the non-wide
# ones.  Only the libraries are taken from the second build; its headers and
# programs would otherwise overwrite the wide ones.
#
# One deliberate departure from LFN-2.md: --with-termlib is NOT used.
#
# It splits the terminfo half of the library out into libtinfo(w), which
# sounds tidy and breaks cross-builds in a way that is genuinely hard to
# diagnose.  Software probes the *host* for ncurses (ncursesw6-config, or a
# distro .pc file) and gets back "-lncursesw" alone, because Arch — like most
# distributions — does not split.  It then links against our split library,
# and the link fails on `stdscr` (util-linux/irqtop), or worse, quietly
# resolves against the host's copy and produces a binary that dies at runtime
# inside the guest.  Building the way the host is built removes the whole
# class of failure.  libtinfo.so.6 / libtinfow.so.6 are provided as symlinks,
# exactly as Arch provides them, so anything asking for -ltinfo still links.
source "$LFN_PROJ/scripts/lib/prologue.sh"
use_guest_flags

tarball=$(fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz")
srcdir=$(extract "$tarball")

# Clear out anything a previous run of this stage left behind, so that stale
# real libraries cannot shadow the fresh install.  The tinfo/tinfow/curses
# compat symlinks are deliberately NOT included here: they are relative
# symlinks pointing at libncurses(w).so.6 by name, so they resolve correctly
# to the freshly-installed library the moment it lands, and something in the
# guest tree (e.g. an already-built zsh) may need to exec through them while
# this very install is still in progress.  Deleting them up front would leave
# that window with no library to satisfy the dependency.
step "clearing previous ncurses libraries"
rm -f "$LFN"/usr/lib/lib{ncurses,ncursesw,menu,menuw,form,formw,panel,panelw}.so* \
      "$LFN"/usr/lib/pkgconfig/{ncurses,ncursesw,tinfo,tinfow,menu,menuw,form,formw,panel,panelw}.pc 2>/dev/null || true

common_opts=(
  --prefix=/usr
  --mandir=/usr/share/man
  --with-shared
  --without-normal            # shared only, no static archives
  --without-debug
  --without-ada
  --without-cxx-binding       # keeps libstdc++ out of the guest for now
  --without-tests
  --with-versioned-syms
  --enable-overwrite          # headers in /usr/include, not /usr/include/ncursesw
  --disable-stripping
  --enable-pc-files
  --with-pkg-config-libdir=/usr/lib/pkgconfig
  # Pinned rather than probed: configure otherwise honours whatever TERMINFO
  # the *host* terminal exported and installs the database somewhere the
  # guest will never look.
  --with-default-terminfo-dir=/usr/share/terminfo
  --with-terminfo-dirs=/usr/share/terminfo:/etc/terminfo
)

# ---------------------------------------------------------------- wide -----
bdir="$BUILD/ncurses-w"; rm -rf "$bdir"; mkdir -p "$bdir"
step "configure ncurses (widec)"
( cd "$bdir" && "$srcdir/configure" "${common_opts[@]}" --enable-widec ) \
  || die "ncurses(w) configure failed"

# run_tic.sh prepends DESTDIR/usr/bin to PATH and normally invokes its shared-
# library wrapper as plain `sh`.  On a retry after zsh has already been built,
# that resolves to $LFN/usr/bin/sh -> zsh, i.e. a guest binary, during a host
# install.  The guest zsh can require the ncurses library which is being
# replaced right now and fails before the wrapper gets a chance to set its
# LD_LIBRARY_PATH.  This wrapper is a host-side build helper, so pin its shell
# to the host path.  tic itself still runs against the just-built libraries.
sed -i 's|SHLIB="sh |SHLIB="/bin/sh |' "$bdir/misc/run_tic.sh"
grep -q 'SHLIB="/bin/sh ' "$bdir/misc/run_tic.sh" \
  || die "could not pin ncurses run_tic wrapper to host /bin/sh"

make -C "$bdir" -j"$JOBS" || die "ncurses(w) build failed"
frun make -C "$bdir" install DESTDIR="$LFN" || die "ncurses(w) install failed"

# ------------------------------------------------------------ non-wide -----
bdir2="$BUILD/ncurses"; rm -rf "$bdir2"; mkdir -p "$bdir2"
step "configure ncurses (non-widec, libraries only)"
( cd "$bdir2" && "$srcdir/configure" "${common_opts[@]}" --disable-widec ) \
  || die "ncurses configure failed"
make -C "$bdir2" -j"$JOBS" libs || die "ncurses build failed"
step "copy non-wide libraries into the tree"
cp -a "$bdir2"/lib/lib*.so* "$LFN/usr/lib/"

# ------------------------------------------------ termlib compatibility -----
# No separate libtinfo is built, so provide the names software asks for.
# This mirrors what Arch ships.
cd "$LFN/usr/lib"
for abi in .so.6 .so; do
  ln -sfn "libncursesw$abi" "libtinfow$abi"
  ln -sfn "libncurses$abi"  "libtinfo$abi"
done
ln -sfn libncursesw.so libcurses.so       # some configure scripts want -lcurses
cd - >/dev/null

# pkg-config must agree, or a package that Requires: tinfo will not configure.
# Only the wide build is installed in full, so ncursesw.pc is the template for
# all four names; the non-wide libraries were copied in by hand above.
template="$LFN/usr/lib/pkgconfig/ncursesw.pc"
[[ -f $template ]] || die "ncursesw.pc was not installed"
for name in tinfo tinfow ncurses; do
  [[ $name == ncurses && -f "$LFN/usr/lib/pkgconfig/ncurses.pc" ]] && continue
  sed -e "s/^Name: .*/Name: $name/" \
      -e "s/^Description: .*/Description: ncurses $NCURSES_VER, $name interface/" \
      -e "s/-lncursesw/-l$name/g" \
      "$template" > "$LFN/usr/lib/pkgconfig/$name.pc"
done

# ---------------------------------------------------------- sanity ---------
for l in libncursesw.so.6 libtinfow.so.6 libncurses.so.6 libtinfo.so.6; do
  [[ -e "$LFN/usr/lib/$l" ]] || die "ncurses install incomplete: $l missing"
done
sanitize_tree

[[ -f "$LFN/usr/share/terminfo/l/linux" ]] \
  || die "terminfo database missing entry for TERM=linux"
[[ -f "$LFN/usr/share/terminfo/x/xterm-256color" ]] \
  || warn "no xterm-256color terminfo entry (harmless on the serial console)"

drop_build "$bdir"; drop_build "$bdir2"
ok "ncurses $NCURSES_VER installed (wide + non-wide, terminfo present)"
