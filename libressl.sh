#!/bin/sh

# Copyright 2014-present Viktor Szakats. See LICENSE.md

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM
export _VER
export _OUT
export _BAS
export _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  # Cross-tasks

  [ "${_OS}" != 'win' ] && options="--build=${_CROSS_HOST} --host=${_TRIPLET}"

  # Build

  # As of 2022-05 (LibreSSL 3.5.2), autotools does not fully support
  # cross-building using clang. It confuses the compiler with MSVC due to
  # matching its name with 'cl*'. This triggers using .lib extension instead of
  # .a for static and import libs.
  # We can work around by aliasing clang to e.g. 'mingw-clang', which fixes the
  # lib extension, but without further benefit.
  # Then a check fails in 'libtool' before trying to build any DLL. These are
  # bogus warnings [1][2], which are in fact errors, so DLLs are not built.
  # We can neutralize the bogus checks via 's/droppeddeps=yes/#droppeddeps=yes/g'
  # in ./ltmain.sh. But, DLL builds will still fail due to thinking using MSVC and
  # the '-link -EXPORT:<symbol>' option, which fails with clang. Manually setting
  # LD to the mingw-w64 ld tool (= "${_CCPREFIX}ld"), will also result in a wrong
  # command-line, with the '--whole-archive' option in it, and fail.
  #
  # So the options are either to stick with gcc with libressl, or to use clang
  # without publishing DLLs. (Or use CMake, but that has other issues.)
  #
  # This is true for other autotools-built curl dependencies, but in those cases
  # there was no focus or need to build DLLs. The wrong .lib extension can be
  # fixed post-build.
  #
  # [1] "Warning: This system can not link to static lib archive [...]" (when using .lib extension)
  # [2] "Warning: linker path does not have real file for library [...]"

  rm -r -f pkg

  find . -name '*.o'   -delete
  find . -name '*.a'   -delete
  find . -name '*.lo'  -delete
  find . -name '*.la'  -delete
  find . -name '*.lai' -delete
  find . -name '*.Plo' -delete
  find . -name '*.pc'  -delete
  find . -name '*.dll' -delete
  find . -name '*.exe' -delete

  export LDFLAGS="${_OPTM}"
  export CPPFLAGS=''
  ldonly=''

  if [ "${CC}" = 'mingw-clang' ]; then
    export CC='clang'
    if [ "${_OS}" != 'win' ]; then
      options="${options} --target=${_TRIPLET} --with-sysroot=${_SYSROOT}"
      LDFLAGS="${LDFLAGS} -target ${_TRIPLET} --sysroot ${_SYSROOT}"
      [ "${_OS}" = 'linux' ] && ldonly="${ldonly} -L$(find "/usr/lib/gcc/${_TRIPLET}" -name '*posix' | head -n 1)"
    fi
    export AR="${_CCPREFIX}ar"
    export NM="${_CCPREFIX}nm"
    export RANLIB="${_CCPREFIX}ranlib"
    export CFLAGS="${LDFLAGS} -Wno-inconsistent-dllimport"
  else
    export CC="${_CCPREFIX}gcc -static-libgcc"
    export CFLAGS="${LDFLAGS} -Wno-attributes"
  fi

  CFLAGS="${CFLAGS} -fno-ident -O3 -Wa,--noexecstack"
  LDFLAGS="${LDFLAGS}${ldonly}"
  [ "${_CPU}" = 'x86' ] && CFLAGS="${CFLAGS} -fno-asynchronous-unwind-tables"

  _prefix='C:/Windows/libressl'
  _ssldir="ssl"

  # shellcheck disable=SC2086
  ./configure ${options} \
    --disable-dependency-tracking \
    --disable-silent-rules \
    --disable-tests \
    --silent \
    "--prefix=${_prefix}" \
    "--with-openssldir=${_prefix}/${_ssldir}"
# make clean > /dev/null
  # Ending slash required.
  make --jobs 2 install "DESTDIR=$(pwd)/pkg/" >/dev/null # 2>&1

  # DESTDIR= + --prefix=
  # LibreSSL does not strip the drive letter
  #   ./libressl/pkg/C:/Windows/libressl
  # Some tools (e.g CMake) will become weird when colons appear in
  # a filename, so move results to a sane, standard path:

  _pkg='pkg/usr/local'
  mkdir -p 'pkg/usr'
  mv "pkg/${_prefix}" "${_pkg}"

  # Build fixups for clang

  # 'configure' misdetects CC=clang as MSVC and then uses '.lib'
  # extension. Rename these to '.a':
  for l in libcrypto libssl libtls; do
    if [ -f "${_pkg}/lib/${l}.lib" ]; then
      sed -i.bak "s|\.lib'$|.a'|g" "${_pkg}/lib/${l}.la"
      mv "${_pkg}/lib/${l}.lib" "${_pkg}/lib/${l}.a"
    fi
  done

  # List files created

  find "${_pkg}" | grep -a -v -F '/share/' | sort

  # Make steps for determinism

  readonly _ref='ChangeLog'

  "${_CCPREFIX}strip" --preserve-dates --enable-deterministic-archives --strip-debug ${_pkg}/lib/*.a

  touch -c -r "${_ref}" ${_pkg}/lib/*.a
  touch -c -r "${_ref}" ${_pkg}/lib/pkgconfig/*.pc
  touch -c -r "${_ref}" ${_pkg}/include/openssl/*.h
  touch -c -r "${_ref}" ${_pkg}/include/*.h

  # Tests

  for bin in \
    ${_pkg}/bin/openssl.exe \
  ; do
    file "${bin}"
    # Produce 'openssl version -a'-like output without executing the build:
    strings "${bin}" | grep -a -E '^(LibreSSL [0-9]|built on: |compiler: |platform: |[A-Z]+DIR: )' || true
  done

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(mktemp -d)/${_BAS}"

  mkdir -p "${_DST}/include/openssl"
  mkdir -p "${_DST}/lib/pkgconfig"

  cp -f -p ${_pkg}/lib/*.a             "${_DST}/lib"
  cp -f -p ${_pkg}/lib/pkgconfig/*.pc  "${_DST}/lib/pkgconfig/"
  cp -f -p ${_pkg}/include/openssl/*.h "${_DST}/include/openssl/"
  cp -f -p ${_pkg}/include/*.h         "${_DST}/include/"
  cp -f -p ChangeLog                   "${_DST}/ChangeLog.txt"
  cp -f -p COPYING                     "${_DST}/COPYING.txt"
  cp -f -p README.md                   "${_DST}/"

  ../_pkg.sh "$(pwd)/${_ref}"
)
