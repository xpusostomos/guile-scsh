# PKGBUILD -- guile-scsh
#
# Builds a package that installs the whole thing where Guile already looks:
#
#   /usr/share/guile/site/3.0/{scsh,editor,script}/*.scm
#   /usr/lib/guile/3.0/site-ccache/{scsh,editor,script}/*.go
#   /usr/bin/scsh
#   /usr/share/man/man1/scsh.1
#
# Those are the directories `guile-config info sitedir' and
# `guile-config info siteccachedir' report on a stock Arch guile; the Makefile
# derives them from PREFIX, which is why no paths are spelled out here.
#
# Build it from a checkout:
#
#   cd /path/to/guile-scsh && makepkg -f
#
# makepkg runs in $srcdir, which is empty for a sourceless build, so build()
# and package() go back to $startdir -- the directory holding this file.  For a
# release package, replace the source=() line with a tarball:
#
#   source=("$pkgname-$pkgver.tar.gz::https://.../$pkgname-$pkgver.tar.gz")

pkgname=guile-scsh
pkgver=0.1.0
pkgrel=1
pkgdesc="scsh -- the Scheme shell, with a structural line editor"
arch=('any')
url="https://github.com/chrisbitmead/guile-scsh"
license=('BSD')
depends=('guile')
makedepends=('guile')
# nothing here is ELF, and the .go files must not be touched
options=(!strip)
source=()

build() {
  cd "$startdir"
  make
}

package() {
  cd "$startdir"
  make install DESTDIR="$pkgdir" PREFIX=/usr
  install -Dm644 COPYING "$pkgdir/usr/share/licenses/$pkgname/COPYING"
}