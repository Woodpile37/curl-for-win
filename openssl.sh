#!/bin/sh

# Copyright 2014-present Viktor Szakats. See LICENSE.md

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM
export _VER
export _OUT
export _BAS
export _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"; [ -n "${2:-}" ] && _NAM="$2"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  if [ "${_OS}" = 'win' ]; then
    # Required on MSYS2 for pod2man and pod2html in 'make install' phase
    export PATH="${PATH}:/usr/bin/core_perl"
  fi

  readonly _ref='CHANGES.md'

  case "${_OS}" in
    bsd|mac) unixts="$(TZ=UTC stat -f '%m' "${_ref}")";;
    *)       unixts="$(TZ=UTC stat --format '%Y' "${_ref}")";;
  esac

  # Build

  rm -r -f pkg

  find . -name '*.o'   -delete
  find . -name '*.obj' -delete
  find . -name '*.a'   -delete
  find . -name '*.pc'  -delete
  find . -name '*.def' -delete
  find . -name '*.dll' -delete
  find . -name '*.exe' -delete
  find . -name '*.tmp' -delete

  [ "${_CPU}" = 'x86' ] && options='mingw'
  [ "${_CPU}" = 'x64' ] && options='mingw64'
  options="${options} no-filenames"
  [ "${_CPU}" = 'x64' ] && options="${options} enable-ec_nistp_64_gcc_128"
  [ "${_CPU}" = 'x86' ] && options="${options} -fno-asynchronous-unwind-tables -D_WIN32_WINNT=0x0501"

  if [ "${CC}" = 'mingw-clang' ]; then
    # To avoid warnings when passing C compiler options to the linker
    options="${options} -Wno-unused-command-line-argument"
    export CC=clang
    if [ "${_OS}" != 'win' ]; then
      # Include the target specifier in the CC variable. This hack is necessary
      # because OpenSSL 3.x detects the symbol prefix for dynamically generated
      # assembly source code by running ${CC} and extracting the value of the
      # macro __USER_LABEL_PREFIX__ [1]. On macOS, with pure 'clang', this
      # returns '_' (as of Homebrew LLVM 13.0.1). This causes all exported
      # assembly function names getting an underscore prefix. Then, when
      # building OpenSSL libraries into executables, the linker will not find
      # these symbols, breaking the builds, including openssl.exe and OpenSSL
      # DLLs.
      # [1]: https://github.com/openssl/openssl/blob/openssl-3.0.2/crypto/perlasm/x86_64-xlate.pl#L91
      # On Linux, this was not an issue, and it seems to affect x64 targets.
      # But enable the workaround in all cross-builds anyway.
      CC="${CC} --target=${_TRIPLET}"

      options="${options} --sysroot=${_SYSROOT}"
      [ "${_OS}" = 'linux' ] && options="-L$(find "/usr/lib/gcc/${_TRIPLET}" -name '*posix' | head -n 1) ${options}"
    fi
    export AR="${_CCPREFIX}ar"
    export NM="${_CCPREFIX}nm"
    export RANLIB="${_CCPREFIX}ranlib"
    _CONF_CCPREFIX=
  else
    unset CC
    _CONF_CCPREFIX="${_CCPREFIX}"
  fi

  # Patch OpenSSL ./Configure to:
  # - make it accept Windows-style absolute paths as --prefix. Without the
  #   patch it misidentifies all such absolute paths as relative ones and
  #   aborts.
  #   Reported: https://github.com/openssl/openssl/issues/9520
  # - allow no-apps option to omit building openssl.exe.
  sed \
    -e 's|die "Directory given with --prefix|print "Directory given with --prefix|g' \
    -e 's|"aria",$|"apps", "aria",|g' \
    < ./Configure > ./Configure-patched
  chmod a+x ./Configure-patched

  # Space or backslash not allowed. Needs to be a folder restricted
  # to Administrators across Windows installations, versions and
  # configurations. We do avoid using the new default prefix set since
  # OpenSSL 1.1.1d, because by using the C:\Program Files*\ value, the
  # prefix remains vulnerable on localized Windows versions. The default
  # below will give a "more secure" configuration for most Windows
  # installations. Also notice that said OpenSSL default breaks OpenSSL's
  # own build system when used in cross-build scenarios. I submitted the
  # working patch, but closed subsequently due to mixed/no response.
  # The secure solution would be to disable loading anything from hard-coded
  # paths and preferably to detect OS location at runtime and adjust config
  # paths accordingly; none supported by OpenSSL.
  _prefix='C:/Windows/System32/OpenSSL'
  _ssldir="ssl"

  # 'no-dso' implies 'no-dynamic-engine' which in turn compiles in these
  # engines non-dynamically. To avoid them, along with their system DLL
  # dependencies and DLL imports, we explicitly disable them one by one in
  # the 'no-capieng ...' line.

  # shellcheck disable=SC2086
  ./Configure-patched ${options} \
    "--cross-compile-prefix=${_CONF_CCPREFIX}" \
    -fno-ident \
    -Wl,--nxcompat -Wl,--dynamicbase \
    no-legacy \
    no-apps \
    no-capieng no-loadereng no-padlockeng \
    no-module \
    no-dso \
    no-shared \
    no-idea \
    no-unit-test \
    no-tests \
    no-makedepend \
    "--prefix=${_prefix}" \
    "--openssldir=${_ssldir}"
  SOURCE_DATE_EPOCH=${unixts} TZ=UTC make --jobs 2
  # Ending slash required.
  make --jobs 2 install "DESTDIR=$(pwd)/pkg/" >/dev/null # 2>&1

  # DESTDIR= + --prefix=
  # OpenSSL 3.x does not strip the drive letter anymore:
  #   ./openssl/pkg/C:/Windows/System32/OpenSSL
  # Some tools (e.g CMake) will become weird when colons appear in
  # a filename, so move results to a sane, standard path:

  _pkg='pkg/usr/local'
  mkdir -p 'pkg/usr'
  mv "pkg/${_prefix}" "${_pkg}"

  # Rename 'lib64' to 'lib'. This is what most packages expect.

  if [ "${_CPU}" = 'x64' ]; then
    mv "${_pkg}/lib64" "${_pkg}/lib"
    sed -i.bak 's|/lib64|/lib|g' ${_pkg}/lib/pkgconfig/*.pc
  fi

  # List files created

  find "${_pkg}" | grep -a -v -F '/share/' | sort

  # Make steps for determinism

  "${_CCPREFIX}strip" --preserve-dates --enable-deterministic-archives --strip-debug ${_pkg}/lib/*.a

  touch -c -r "${_ref}" ${_pkg}/lib/*.a
  touch -c -r "${_ref}" ${_pkg}/lib/pkgconfig/*.pc
  touch -c -r "${_ref}" ${_pkg}/include/openssl/*.h

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(mktemp -d)/${_BAS}"

  mkdir -p "${_DST}/include/openssl"
  mkdir -p "${_DST}/lib/pkgconfig"

  cp -f -p ${_pkg}/lib/*.a             "${_DST}/lib"
  cp -f -p ${_pkg}/lib/pkgconfig/*.pc  "${_DST}/lib/pkgconfig/"
  cp -f -p ${_pkg}/include/openssl/*.h "${_DST}/include/openssl/"
  cp -f -p CHANGES.md                  "${_DST}/"
  cp -f -p LICENSE.txt                 "${_DST}/"
  cp -f -p README.md                   "${_DST}/"
  cp -f -p FAQ.md                      "${_DST}/"
  cp -f -p NEWS.md                     "${_DST}/"

  [ "${_NAM}" = 'openssl-quic' ] && cp -f -p README-OpenSSL.md "${_DST}/"

  if [ "${_CPU}" = 'x86' ] && [ -r ms/applink.c ]; then
    touch -c -r "${_ref}" ms/applink.c
    cp -f -p ms/applink.c "${_DST}/include/openssl/"
  fi

  ../_pkg.sh "$(pwd)/${_ref}"
)
