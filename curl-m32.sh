#!/bin/sh

# Copyright 2014-present Viktor Szakats. See LICENSE.md
# SPDX-License-Identifier: MIT

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM _VER _OUT _BAS _DST

_NAM="$(basename "$0" | cut -f 1 -d '.' | sed 's/-m32//')"
_VER="$1"

(
  cd "${_NAM}"  # mandatory component

  # Always delete targets, including ones made for a different CPU.
  find src -name '*.exe' -delete
  find src -name '*.map' -delete
  find lib -name '*.dll' -delete
  find lib -name '*.def' -delete
  find lib -name '*.map' -delete

  rm -r -f "${_PKGDIR}"

  # Build

  oldm32=
  if ! grep -a -q -F 'CPPFLAGS' 'lib/Makefile.m32'; then
    oldm32=1
  fi

  options='mingw32-ipv6-sspi-srp'

  export ARCH='custom'

  export CC="${_CC_GLOBAL}"
  export CFLAGS="${_CFLAGS_GLOBAL} -O3 -W -Wall"
  export CPPFLAGS="${_CPPFLAGS_GLOBAL} -DNDEBUG -DOS=\\\"${_TRIPLET}\\\""
  export RCFLAGS="${_RCFLAGS_GLOBAL}"
  export LDFLAGS="${_LDFLAGS_GLOBAL} -Wl,--nxcompat -Wl,--dynamicbase"
  export LIBS="${_LIBS_GLOBAL}"

  LDFLAGS_BIN=''
  LDFLAGS_LIB=''

  # Use -DCURL_STATICLIB when compiling libcurl. This option prevents
  # marking public libcurl functions as 'exported'. Useful to avoid the
  # chance of libcurl functions getting exported from final binaries when
  # linked against the static libcurl lib.
  CPPFLAGS="${CPPFLAGS} -DCURL_STATICLIB"

  if [ "${CURL_VER_}" = '7.85.0' ]; then
    # Match configuration with other build tools.
    CPPFLAGS="${CPPFLAGS} -D_FILE_OFFSET_BITS=64"
    CPPFLAGS="${CPPFLAGS} -DHAVE_SETJMP_H -DHAVE_STRING_H -DHAVE_SIGNAL"
    CPPFLAGS="${CPPFLAGS} -DHAVE_STDBOOL_H -DHAVE_BOOL_T"
    CPPFLAGS="${CPPFLAGS} -DHAVE_INET_PTON -DHAVE_INET_NTOP"
    CPPFLAGS="${CPPFLAGS} -DHAVE_LIBGEN_H"
    CPPFLAGS="${CPPFLAGS} -DHAVE_FTRUNCATE -DHAVE_BASENAME -DHAVE_STRTOK_R"
    CPPFLAGS="${CPPFLAGS} -DSIZEOF_OFF_T=8"
  fi

  # CPPFLAGS added after this point only affect libcurl.

  if [ "${_CPU}" = 'x86' ]; then
    LDFLAGS_BIN="${LDFLAGS_BIN} -Wl,--pic-executable,-e,_mainCRTStartup"
  else
    LDFLAGS_BIN="${LDFLAGS_BIN} -Wl,--pic-executable,-e,mainCRTStartup"
    LDFLAGS_LIB="${LDFLAGS_LIB} -Wl,--image-base,0x150000000"
    LDFLAGS="${LDFLAGS} -Wl,--high-entropy-va"
  fi

  if [ ! "${_BRANCH#*pico*}" = "${_BRANCH}" ] || \
     [ ! "${_BRANCH#*nano*}" = "${_BRANCH}" ]; then
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_ALTSVC=1"
  fi

  if [ ! "${_BRANCH#*pico*}" = "${_BRANCH}" ]; then
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_CRYPTO_AUTH=1"
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_DICT=1 -DCURL_DISABLE_FILE=1 -DCURL_DISABLE_GOPHER=1 -DCURL_DISABLE_MQTT=1 -DCURL_DISABLE_RTSP=1 -DCURL_DISABLE_SMB=1 -DCURL_DISABLE_TELNET=1 -DCURL_DISABLE_TFTP=1"
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_FTP=1"
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_IMAP=1 -DCURL_DISABLE_POP3=1 -DCURL_DISABLE_SMTP=1"
    CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_LDAP=1 -DCURL_DISABLE_LDAPS=1"
  else
    options="${options}-ldaps"
  fi

  if [ ! "${_BRANCH#*unicode*}" = "${_BRANCH}" ]; then
    options="${options}-unicode"
  fi

  if [ "${CW_MAP}" = '1' ]; then
    LDFLAGS_BIN="${LDFLAGS_BIN} -Wl,-Map,curl.map"
    # shellcheck disable=SC2153
    LDFLAGS_LIB="${LDFLAGS_LIB} -Wl,-Map,libcurl${_CURL_DLL_SUFFIX}.map"
  fi

  # Generate .def file for libcurl by parsing curl headers. Useful to export
  # the libcurl functions meant to be exported.
  # Without this, the default linker logic kicks in, whereas it exports every
  # public function, if none is marked for export explicitly. This leads to
  # exporting every libcurl public function, as well as any other ones from
  # statically linked dependencies, resulting in a larger .dll, an inflated
  # implib and a non-standard list of exported functions.
  echo 'EXPORTS' > libcurl.def
  {
    # CURL_EXTERN CURLcode curl_easy_send(CURL *curl, const void *buffer,
    grep -a -h '^CURL_EXTERN ' include/curl/*.h | grep -a -h -F '(' \
      | sed 's/CURL_EXTERN \([a-zA-Z_\* ]*\)[\* ]\([a-z_]*\)(\(.*\)$/\2/g'
    # curl_easy_option_by_name(const char *name);
    grep -a -h -E '^ *\*? *[a-z_]+ *\(.+\);$' include/curl/*.h \
      | sed -E 's/^ *\*? *([a-z_]+) *\(.+$/\1/g'
  } | grep -a -v '^$' | sort | tee -a libcurl.def
  LDFLAGS_LIB="${LDFLAGS_LIB} ../libcurl.def"

  if [ -n "${_ZLIB}" ]; then
    options="${options}-zlib"
    # Makefile.m32 expects the headers and lib in ZLIB_PATH, so adjust them
    # manually:
    export ZLIB_PATH="../../${_ZLIB}/${_PP}/include"
    LDFLAGS="${LDFLAGS} -L../../${_ZLIB}/${_PP}/lib"

    # Make sure to link static zlib, avoiding a dependency on `zlib1.dll`
    # in `libcurl.dll`. Some environments (e.g. MSYS2), offer `libz.dll.a`
    # alongside `libz.a` causing the linker to pick up the shared flavor.
    LDFLAGS_LIB="${LDFLAGS_LIB} -Wl,-Bstatic -lz -Wl,-Bdynamic"
  fi
  if [ -d ../brotli ] && [ "${_BRANCH#*nobrotli*}" = "${_BRANCH}" ]; then
    options="${options}-brotli"
    export BROTLI_PATH="../../brotli/${_PP}"
    export BROTLI_LIBS='-Wl,-Bstatic -lbrotlidec -lbrotlicommon -Wl,-Bdynamic'
  fi
  if [ -d ../zstd ] && [ "${_BRANCH#*nozstd*}" = "${_BRANCH}" ]; then
    options="${options}-zstd"
    export ZSTD_PATH="../../zstd/${_PP}"
    export ZSTD_LIBS='-Wl,-Bstatic -lzstd -Wl,-Bdynamic'
  fi

  h3=0

  if [ -n "${_OPENSSL}" ]; then
    options="${options}-ssl"
    if [ -n "${oldm32}" ]; then
      OPENSSL_PATH="../../${_OPENSSL}/${_PP}"
      export OPENSSL_INCLUDE="${OPENSSL_PATH}/include"
      export OPENSSL_LIBPATH="${OPENSSL_PATH}/lib"
      CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG"
    else
      export OPENSSL_PATH="../../${_OPENSSL}/${_PP}"
    fi
    export OPENSSL_LIBS='-lssl -lcrypto'

    if [ "${_OPENSSL}" = 'boringssl' ]; then
      CPPFLAGS="${CPPFLAGS} -DCURL_BORINGSSL_VERSION=\\\"$(printf '%.8s' "${BORINGSSL_VER_}")\\\""
      if [ "${_TOOLCHAIN}" = 'mingw-w64' ] && [ "${_CPU}" = 'x64' ] && [ "${_CRT}" = 'ucrt' ]; then  # FIXME
        # Non-production workaround for:
        # mingw-w64 x64 winpthread static lib incompatible with UCRT.
        # ```c
        # /*
        #    clang
        #    $ /usr/local/opt/llvm/bin/clang -fuse-ld=lld \
        #        -target x86_64-w64-mingw32 --sysroot /usr/local/opt/mingw-w64/toolchain-x86_64 \
        #        test.c -D_UCRT -Wl,-Bstatic -lpthread -Wl,-Bdynamic -lucrt
        #
        #    gcc
        #    $ x86_64-w64-mingw32-gcc -dumpspecs | sed 's/-lmsvcrt/-lucrt/g' > gcc-specs-ucrt
        #    $ x86_64-w64-mingw32-gcc -specs=gcc-specs-ucrt \
        #        test.c -D_UCRT -Wl,-Bstatic -lpthread -Wl,-Bdynamic -lucrt
        #
        #    ``` clang ->
        #    ld.lld: error: undefined symbol: _setjmp
        #    >>> referenced by ../src/thread.c:1518
        #    >>>               libpthread.a(libwinpthread_la-thread.o):(pthread_create_wrapper)
        #    clang-15: error: linker command failed with exit code 1 (use -v to see invocation)
        #    ```
        #    ``` gcc ->
        #    /usr/local/Cellar/mingw-w64/10.0.0_3/toolchain-x86_64/bin/x86_64-w64-mingw32-ld: /usr/local/Cellar/mingw-w64/10.0.0_3/toolchain-x86_64/lib/gcc/x86_64-w64-mingw32/12.2.0/../../../../x86_64-w64-mingw32/lib/../lib/libpthread.a(libwinpthread_la-thread.o): in function `pthread_create_wrapper':
        #    /private/tmp/mingw-w64-20220820-4738-rfttcn/mingw-w64-v10.0.0/mingw-w64-libraries/winpthreads/build-x86_64/../src/thread.c:1518: undefined reference to `_setjmp'
        #    collect2: error: ld returned 1 exit status
        #    ```
        #  */
        # #include <pthread.h>
        # int main(void) {
        #   pthread_rwlock_t lock;
        #   pthread_rwlock_init(&lock, NULL);
        #   return 0;
        # }
        # ```
        # Ref: https://github.com/niXman/mingw-builds/issues/498
        OPENSSL_LIBS="${OPENSSL_LIBS} -Wl,-Bdynamic -lpthread -Wl,-Bstatic"
      else
        OPENSSL_LIBS="${OPENSSL_LIBS} -Wl,-Bstatic -lpthread -Wl,-Bdynamic"
      fi
      h3=1
    elif [ "${_OPENSSL}" = 'libressl' ]; then
      h3=1
    elif [ "${_OPENSSL}" = 'openssl-quic' ] || [ "${_OPENSSL}" = 'openssl' ]; then
      # Workaround for 3.x deprecation warnings
      CPPFLAGS="${CPPFLAGS} -DOPENSSL_SUPPRESS_DEPRECATED"
      [ "${_OPENSSL}" = 'openssl-quic' ] && h3=1
    fi
  fi

  multissl=0

  if [ -d ../wolfssl ]; then
    CPPFLAGS="${CPPFLAGS} -DUSE_WOLFSSL -DSIZEOF_LONG_LONG=8"
    CPPFLAGS="${CPPFLAGS} -I../../wolfssl/${_PP}/include"
    LDFLAGS="${LDFLAGS} -L../../wolfssl/${_PP}/lib"
    LIBS="${LIBS} -lwolfssl"
    multissl=1
    h3=1
  fi

  if [ -d ../mbedtls ]; then
    CPPFLAGS="${CPPFLAGS} -DUSE_MBEDTLS"
    CPPFLAGS="${CPPFLAGS} -I../../mbedtls/${_PP}/include"
    LDFLAGS="${LDFLAGS} -L../../mbedtls/${_PP}/lib"
    LIBS="${LIBS} -lmbedtls -lmbedx509 -lmbedcrypto"
    multissl=1
  fi

  [ "${multissl}" = '1' ] && CPPFLAGS="${CPPFLAGS} -DCURL_WITH_MULTI_SSL"  # Fixup for cases undetected by Makefile.m32

  options="${options}-schannel"
  CPPFLAGS="${CPPFLAGS} -DHAS_ALPN"

  if [ -d ../wolfssh ] && [ -d ../wolfssl ]; then
    CPPFLAGS="${CPPFLAGS} -DUSE_WOLFSSH"
    CPPFLAGS="${CPPFLAGS} -I../../wolfssh/${_PP}/include"
    LDFLAGS="${LDFLAGS} -L../../wolfssh/${_PP}/lib"
    LIBS="${LIBS} -lwolfssh"
  elif [ -d ../libssh ]; then
    CPPFLAGS="${CPPFLAGS} -DUSE_LIBSSH"
    [ "${CURL_VER_}" = '7.85.0' ] && CPPFLAGS="${CPPFLAGS} -DHAVE_LIBSSH_LIBSSH_H"
    CPPFLAGS="${CPPFLAGS} -DLIBSSH_STATIC"
    CPPFLAGS="${CPPFLAGS} -I../../libssh/${_PP}/include"
    LDFLAGS="${LDFLAGS} -L../../libssh/${_PP}/lib"
    LIBS="${LIBS} -lssh"
  elif [ -d ../libssh2 ]; then
    options="${options}-ssh2"
    export LIBSSH2_PATH="../../libssh2/${_PP}"
    if [ -n "${oldm32}" ]; then
      LDFLAGS="${LDFLAGS} -L${LIBSSH2_PATH}/lib"
    fi
  fi
  if [ -d ../nghttp2 ]; then
    options="${options}-nghttp2"
    export NGHTTP2_PATH="../../nghttp2/${_PP}"
    CPPFLAGS="${CPPFLAGS} -DNGHTTP2_STATICLIB"
  fi

  [ "${_BRANCH#*noh3*}" = "${_BRANCH}" ] || h3=0

  if [ "${h3}" = '1' ] && [ -d ../nghttp3 ] && [ -d ../ngtcp2 ]; then
    options="${options}-nghttp3-ngtcp2"
    export NGHTTP3_PATH="../../nghttp3/${_PP}"
    CPPFLAGS="${CPPFLAGS} -DNGHTTP3_STATICLIB"
    export NGTCP2_PATH="../../ngtcp2/${_PP}"
    CPPFLAGS="${CPPFLAGS} -DNGTCP2_STATICLIB"
    export NGTCP2_LIBS='-lngtcp2'
    if [ "${_OPENSSL}" = 'boringssl' ]; then
      NGTCP2_LIBS="${NGTCP2_LIBS} -lngtcp2_crypto_boringssl"
    elif [ "${_OPENSSL}" = 'openssl-quic' ] || [ "${_OPENSSL}" = 'libressl' ]; then
      NGTCP2_LIBS="${NGTCP2_LIBS} -lngtcp2_crypto_openssl"
    elif [ -d ../wolfssl ]; then
      NGTCP2_LIBS="${NGTCP2_LIBS} -lngtcp2_crypto_wolfssl"
    fi
  fi
  if [ -d ../cares ]; then
    options="${options}-ares"
    if [ -n "${oldm32}" ]; then
      export LIBCARES_PATH="../../cares/${_PP}/lib"
      CPPFLAGS="${CPPFLAGS} -I../../cares/${_PP}/include"
    else
      export LIBCARES_PATH="../../cares/${_PP}"
    fi
    CPPFLAGS="${CPPFLAGS} -DCARES_STATICLIB"
  fi
  if [ -d ../gsasl ]; then
    options="${options}-gsasl"
    export LIBGSASL_PATH="../../gsasl/${_PP}"
  fi
  if [ -d ../libidn2 ]; then
    options="${options}-idn2"
    export LIBIDN2_PATH="../../libidn2/${_PP}"

    if [ -d ../libpsl ]; then
      CPPFLAGS="${CPPFLAGS} -DUSE_LIBPSL"
      CPPFLAGS="${CPPFLAGS} -I../../libpsl/${_PP}/include"
      LDFLAGS="${LDFLAGS} -L../../libpsl/${_PP}/lib"
      LIBS="${LIBS} -lpsl"
    fi

    if [ -d ../libiconv ]; then
      LDFLAGS="${LDFLAGS} -L../../libiconv/${_PP}/lib"
      LIBS="${LIBS} -liconv"
    fi
    if [ -d ../libunistring ]; then
      LDFLAGS="${LDFLAGS} -L../../libunistring/${_PP}/lib"
      LIBS="${LIBS} -lunistring"
    fi
  elif [ "${_BRANCH#*pico*}" = "${_BRANCH}" ]; then
    options="${options}-winidn"
  fi

  [ "${_BRANCH#*noftp*}" != "${_BRANCH}" ] && CPPFLAGS="${CPPFLAGS} -DCURL_DISABLE_FTP=1"

  [ "${CURL_VER_}" != '7.85.0' ] && CPPFLAGS="${CPPFLAGS} -DUSE_WEBSOCKETS"

  if [ "${CW_DEV_LLD_REPRODUCE:-}" = '1' ] && [ "${_LD}" = 'lld' ]; then
    LDFLAGS_LIB="${LDFLAGS_LIB} -Wl,--reproduce=$(pwd)/$(basename "$0" .sh)-dll.tar"
    LDFLAGS_BIN="${LDFLAGS_BIN} -Wl,--reproduce=$(pwd)/$(basename "$0" .sh)-exe.tar"
  fi

  [ "${CW_DEV_CROSSMAKE_REPRO:-}" = '1' ] && export AR="${AR_NORMALIZE}"

  if [ -n "${oldm32}" ]; then  # Fill curl-specific variables for curl 7.85.0 and earlier
    export CURL_CC="${_CC_GLOBAL}"
    export CURL_STRIP="${_STRIP}"
    export CURL_RC="${RC}"
    export CURL_AR="${AR}"
    export CURL_RANLIB="${RANLIB}"

    export CURL_RCFLAG_EXTRAS="${RCFLAGS}"
    export CURL_CFLAG_EXTRAS="${CFLAGS} ${CPPFLAGS}"
    export CURL_LDFLAG_EXTRAS="${LDFLAGS} ${LIBS}"

    export CURL_LDFLAG_EXTRAS_DLL="${LDFLAGS_LIB}"
    export CURL_LDFLAG_EXTRAS_EXE="${LDFLAGS_BIN}"
  else
    export CURL_LDFLAGS_LIB="${LDFLAGS_LIB}"
    export CURL_LDFLAGS_BIN="${LDFLAGS_BIN}"
  fi

  export CURL_DLL_SUFFIX="${_CURL_DLL_SUFFIX}"
  [ -n "${oldm32}" ] && export CURL_DLL_A_SUFFIX='.dll'

  if [ "${CW_DEV_INCREMENTAL:-}" != '1' ]; then
    if [ "${CW_MAP}" = '1' ]; then
      find src -name '*.map' -delete
      find lib -name '*.map' -delete
    fi
    "${_MAKE}" --jobs="${_JOBS}" --directory=lib --makefile=Makefile.m32 distclean
    "${_MAKE}" --jobs="${_JOBS}" --directory=src --makefile=Makefile.m32 distclean
  fi

  "${_MAKE}" --jobs="${_JOBS}" --directory=lib --makefile=Makefile.m32 CFG="${options}"
  "${_MAKE}" --jobs="${_JOBS}" --directory=src --makefile=Makefile.m32 CFG="${options}"

  # Install manually

  mkdir -p "${_PP}/include/curl"
  mkdir -p "${_PP}/lib"
  mkdir -p "${_PP}/bin"

  cp -f -p ./include/curl/*.h "${_PP}/include/curl/"
  cp -f -p ./src/*.exe        "${_PP}/bin/"
  cp -f -p ./lib/*.dll        "${_PP}/bin/"
  cp -f -p ./lib/*.def        "${_PP}/bin/"
  cp -f -p ./lib/*.a          "${_PP}/lib/"

  if [ "${CW_MAP}" = '1' ]; then
    cp -f -p ./src/*.map "${_PP}/bin/"
    cp -f -p ./lib/*.map "${_PP}/bin/"
  fi

  . ../curl-pkg.sh
)
