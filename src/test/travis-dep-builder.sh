#!/bin/bash
#
#

prefix=$HOME/local
cachedir=$HOME/local/.cache

#
# Ordered list of software to download and install into $prefix.
#  NOTE: Code currently assumes .tar.gz suffix...
#
downloads="\
https://github.com/dun/munge/archive/munge-0.5.11.tar.gz \
https://github.com/jedisct1/libsodium/releases/download/1.0.10/libsodium-1.0.10.tar.gz \
https://github.com/zeromq/zeromq4-1/releases/download/v4.1.4/zeromq-4.1.4.tar.gz \
https://github.com/zeromq/czmq/archive/v3.0.2.tar.gz \
https://s3.amazonaws.com/json-c_releases/releases/json-c-0.11.tar.gz \
http://downloads.sourceforge.net/ltp/lcov-1.10.tar.gz \
http://www.open-mpi.org/software/hwloc/v1.11/downloads/hwloc-1.11.0.tar.gz \
http://www.mpich.org/static/downloads/3.1.4/mpich-3.1.4.tar.gz"

declare -A extra_configure_opts=(\
["zeromq-4.0.4"]="--with-libsodium --with-libsodium-include-dir=\$prefix/include" \
["mpich-3.1.4"]="--disable-fortran --disable-cxx --disable-maintainer-mode --disable-dependency-tracking --enable-shared --disable-wrapper-rpath" \
)

checkouts="\
https://github.com/wolfcw/libfaketime.git \
https://github.com/danmar/cppcheck.git"

declare -A checkout_sha1=(\
["libfaketime"]="b68f2820c4091075fbc205965ec6976f6d241aaa" \
["cppcheck"]="7466a49b216d4ba5e25b48381d85a8c3b2d3a228"
)

declare -A extra_make_opts=(\
["libfaketime"]="LIBDIRNAME=/lib"
["cppcheck"]="CFGDIR=/${prefix}/etc/cppcheck"
)

#
#  Python pip packages
#
pips="\
cffi>=1.1,<1.4 \
coverage"

#
#  Lua rocks files to download and install:
#
declare -A lua_rocks=(\
["posix"]="luaposix" \
)

declare -r prog=${0##*/}
declare -r long_opts="prefix:,cachedir:,verbose,printenv"
declare -r short_opts="vp:c:P"
declare -r usage="\
\n
Usage: $prog [OPTIONS]\n\
Download and install to a local prefix (default=$prefix) dependencies\n\
for building flux-framework/flux-core\n\
\n\
Options:\n\
 -v, --verbose           Be verbose.\n\
 -P, --printenv          Print environment variables to stdout\n\
 -c, --cachedir=DIR      Check for precompiled dependency cache in DIR\n\
 -e, --max-cache-age=N   Expire cache in N days from creation\n\
 -p, --prefix=DIR        Install software into prefix\n
"

die() { echo -e "$prog: $@"; exit 1; }
say() { echo -e "$prog: $@"; }
debug() { test "$verbose" = "t" && say "$@"; }

GETOPTS=`/usr/bin/getopt -u -o $short_opts -l $long_opts -n $prog -- $@`
if test $? != 0; then
    die "$usage"
fi

eval set -- "$GETOPTS"
while true; do
    case "$1" in
      -v|--verbose)          verbose=t;     shift   ;;
      -c|--cachedir)         cachedir="$2"; shift 2 ;;
      -e|--max-cache-age)    cacheage="$2"; shift 2 ;;
      -p|--prefix)           prefix="$2";   shift   ;;
      -P|--printenv)         print_env=1;   shift   ;;
      --)                    shift ; break;         ;;
      *)                     die "Invalid option '$1'\n$usage" ;;
    esac
done

print_env () {
    echo "export LD_LIBRARY_PATH=${prefix}/lib:$LD_LIBRARY_PATH"
    echo "export CPPFLAGS=-I${prefix}/include"
    echo "export LDFLAGS=-L${prefix}/lib"
    echo "export PKG_CONFIG_PATH=${prefix}/lib/pkgconfig"
    echo "export PATH=${PATH}:${HOME}/.local/bin:${HOME}/local/usr/bin:${HOME}/local/bin"
    luarocks path --bin
}

if test -n "$print_env"; then
    print_env
    exit 0
fi

$(print_env)


check_cache ()
{
    test -n "$cachedir" || return 1
    local url=$1
    local cachefile="${cachedir}/${url}"
    test -f "${cachefile}" || return 1
    test -n "$cacheage"    || return 0

    local ctime=$(stat -c%Y ${cachefile})
    local maxage=$((${cacheage}*86400))
    test $ctime -gt $maxage && return 1
}

add_cache ()
{
    test -n "$cachedir" || return 0
    mkdir -p "${cachedir}" &&
    touch "${cachedir}/${1}"
}

pip help >/dev/null 2>&1 || die "Required command pip not installed"
pip install --user $pips || die "Failed to install required python packages"


luarocks help >/dev/null 2>&1 || die "Required command luarocks not installed"

# install rocks
eval `luarocks --local path`
for p in ${!lua_rocks[@]}; do
    if ! lua -l$p -e '' >/dev/null 2>&1; then
        luarocks --local install ${lua_rocks[$p]}
    else
        say "Using cached version of " ${lua_rocks[$p]}
    fi
done

# hack for 'make install' targets that force installation to
#  /lib/systemd if $prefix/lib/systemd/system doesn't exist
mkdir -p ${prefix}/lib/systemd/system

for url in $checkouts; do
    name=$(basename ${url} .git)
    sha1="${checkout_sha1[$name]}"
    make_opts="${extra_make_opts[$name]}"
    configure_opts="${extra_configure_opts[$name]}"
    if check_cache "$name:$sha1:$make_opts:$configure_opts"; then
       say "Using cached version of ${name}"
       continue
    fi
    git clone ${url} ${name} || die "Failed to clone ${url}"
    (
      cd ${name} || die "cd failed"
      if test -n "$sha1"; then
        git checkout $sha1
      fi
      test -x configure && CC=gcc ./configure --prefix=${prefix} \
                  --sysconfdir=${prefix}/etc \
                  $configure_opts || : &&
      make PREFIX=${prefix} $make_opts &&
      make PREFIX=${prefix} $make_opts install
    ) || die "Failed to build and install $name"
    add_cache "$name"
done

for pkg in $downloads; do
    name=$(basename ${pkg} .tar.gz)
    if check_cache "$name"; then
       say "Using cached version of ${name}"
       continue
    fi
    mkdir -p ${name}  || die "Failed to mkdir ${name}"
    (
      cd ${name} &&
      curl -L -O --insecure ${pkg} || die "Failed to download ${pkg}"
      tar --strip-components=1 -xf *.tar.gz || die "Failed to un-tar ${name}"
      test -x configure || ./autogen.sh
      test -x configure && CC=gcc ./configure --prefix=${prefix} \
                  --sysconfdir=${prefix}/etc \
                  ${extra_configure_opts[$name]} || : &&
      make PREFIX=${prefix} &&
      make PREFIX=${prefix} install
    ) || die "Failed to build and install $name"
    add_cache "$name"
done


