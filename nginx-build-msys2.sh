#!/bin/bash

# cmd line switches
for i in "$@"
do
  case $i in
    -t=*|--tag=*)
      NGINX_TAG="${i#*=}"
      shift # past argument=value
    ;;
    -nt=*|--njs-tag=*)
      NJS_TAG="${i#*=}"
      shift # past argument=value
    ;;
    --debug)
      NGINX_DEBUG=1
      shift # past argument=value
    ;;
  esac
done

# create dir for docs
mkdir -p docs

# init
machine_str="$(gcc -dumpmachine | cut -d'-' -f1)"

# workaround git user name and email not set
GIT_USER_NAME="$(git config --global user.name)"
GIT_USER_EMAIL="$(git config --global user.email)"
if [[ "${GIT_USER_NAME}" = "" ]]; then
    git config --global user.name "Build Bot"
fi
if [[ "${GIT_USER_EMAIL}" = "" ]]; then
    git config --global user.email "you@example.com"
fi

# dep versions
ZLIB="$(curl -s 'https://zlib.net/' | grep -ioP 'zlib-(\d+\.)+\d+' | sort -ruV | head -1)"
ZLIB="${ZLIB:-zlib-1.2.11}"
echo $ZLIB
PCRE="$(curl -s 'https://ftp.pcre.org/pub/pcre/' | grep -ioP 'pcre-(\d+\.)+\d+' | sort -ruV | head -1)"
PCRE="${PCRE:-pcre-8.44}"
echo $PCRE
OPENSSL="$(curl -s 'https://www.openssl.org/source/' | grep -ioP 'openssl-1\.(\d+\.)+[a-z\d]+' | sort -ruV | head -1)"
OPENSSL="${OPENSSL:-openssl-1.1.1g}"
echo $OPENSSL

# NJS does not inherit nginx's --with-pcre
# And for some reason, nginx doesn't seem to pick up the locally installed pcre, so both are required
echo "Installing PCRE"
pacman -U --noconfirm http://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-pcre-8.44-1-any.pkg.tar.xz || { echo "Couldn't install PCRE"; exit 1; }

# clone and patch nginx
if [[ -d nginx ]]; then
    cd nginx
    git checkout master
    git branch patch -D
    if [[ "${NGINX_TAG}" == "" ]]; then
        git reset --hard origin || git reset --hard
        git pull
    else
        git reset --hard "${NGINX_TAG}" || git reset --hard
    fi
else
    if [[ "${NGINX_TAG}" == "" ]]; then
        git clone https://github.com/nginx/nginx.git --depth=1 || { echo "Couldn't clone nginx"; exit 1; }
    else
        git clone https://github.com/nginx/nginx.git --depth=1 --branch "${NGINX_TAG}" || { echo "Couldn't clone nginx"; exit 1; }
    fi
    cd nginx
fi
git checkout -b patch
git am -3 ../nginx-*.patch

# clone njs
if [[ -d njs ]]; then
    pushd njs
    git checkout master
    if [[ "${NJS_TAG}" == "" ]]; then
        git reset --hard origin || git reset --hard
        git pull
    else
        git reset --hard "${NJS_TAG}" || git reset --hard
    fi
    popd
else
    if [[ "${NJS_TAG}" == "" ]]; then
        git clone https://github.com/nginx/njs.git --depth=1 || { echo "Couldn't clone njs"; exit 1; }
    else
        git clone https://github.com/nginx/njs.git --depth=1 --branch "${NJS_TAG}" || { echo "Couldn't clone njs"; exit 1; }
    fi
fi

# download deps
wget -c -nv "https://zlib.net/${ZLIB}.tar.xz" || \
  wget -c -nv "http://prdownloads.sourceforge.net/libpng/${ZLIB}.tar.xz" || { echo "Couldn't download zlib"; exit 1; }
tar -xf "${ZLIB}.tar.xz"
wget -c -nv "https://www.openssl.org/source/${OPENSSL}.tar.gz" || { echo "Couldn't download openssl"; exit 1; }
tar -xf "${OPENSSL}.tar.gz"

# dirty workaround for openssl-1.1.1d
if [ "${OPENSSL}" = "openssl-1.1.1d" ]; then
   sed -i 's/return return 0;/return 0;/' openssl-1.1.1d/crypto/threads_none.c
fi

# make changes
make -f docs/GNUmakefile changes
mv -f tmp/*/CHANGES* ../docs/

# copy docs and licenses
cp -f docs/text/LICENSE ../docs/
cp -f docs/text/README ../docs/
cp -pf "${OPENSSL}/LICENSE" '../docs/OpenSSL.LICENSE'
sed -ne '/^ (C) 1995-20/,/^  jloup@gzip\.org/p' "${ZLIB}/README" > '../docs/zlib.LICENSE'
touch -r "${ZLIB}/README" '../docs/zlib.LICENSE'

# configure
configure_args=(
    '--sbin-path=nginx.exe' \
    '--http-client-body-temp-path=temp/client_body' \
    '--http-proxy-temp-path=temp/proxy' \
    '--http-fastcgi-temp-path=temp/fastcgi' \
    '--http-scgi-temp-path=temp/scgi' \
    '--http-uwsgi-temp-path=temp/uwsgi' \
    "--with-pcre=${PCRE}" \
    "--with-zlib=${ZLIB}" \
    "--with-openssl=${OPENSSL}" \
    '--with-openssl-opt=no-asm' \
    '--with-http_ssl_module' \
    '--prefix='
)
echo ${configure_args[@]}
auto/configure ${configure_args[@]} \
    --with-cc-opt='-s -O2 -fno-strict-aliasing -pipe' \
    --with-openssl-opt='no-tests -D_WIN32_WINNT=0x0501' \
     || { echo "Couldn't configure nginx"; exit 1; }

# build
make -j$(nproc) || { echo "Couldn't compile nginx"; exit 1; }
strip -s objs/nginx.exe || { echo "Couldn't strip nginx.exe"; exit 1; }
version="$(cat src/core/nginx.h | grep NGINX_VERSION | grep -ioP '((\d+\.)+\d+)')"
mv -f "objs/nginx.exe" "../nginx-${version}-${machine_str}.exe"

if [ -z ${NGINX_DEBUG+} ]; then
  # re-configure with debugging log
  configure_args+=(--with-debug)
  auto/configure ${configure_args[@]}  \
      --with-cc-opt='-O2 -fno-strict-aliasing -pipe' \
      --with-openssl-opt='no-tests -D_WIN32_WINNT=0x0501' \
       || { echo "Couldn't configure nginx-debug"; exit 1; }

  # re-build with debugging log
  make -j$(nproc)|| { echo "Couldn't compile nginx-debug"; exit 1; }
  mv -f "objs/nginx.exe" "../nginx-${version}-${machine_str}-debug.exe"
fi

# clean up
git checkout master
git branch patch -D
cd ..
