#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# error on undefined environment variables
set -u

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$BOOST_SOURCE_DIR/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

# Libraries on which we depend - please keep alphabetized for maintenance
BOOST_LIBS=(context date_time fiber filesystem iostreams program_options \
            regex stacktrace system thread wave)

BOOST_BUILD_SPAM="-d2 -d+4"             # -d0 is quiet, "-d2 -d+4" allows compilation to be examined

top="$(pwd)"
cd "$BOOST_SOURCE_DIR"
# As of sometime between Boost 1.67 and 1.72, the Boost build engine b2's
# legacy bjam alias is no longer copied to the top-level Boost directory. Use
# b2 directly.
bjam="$(pwd)/b2"
stage="$(pwd)/stage"

[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || fail "You haven't installed the zlib package yet."
                                                     
if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
    # convert from bash path to native OS pathname
    native()
    {
        cygpath -w "$@"
    }
else
    autobuild="$AUTOBUILD"
    # no pathname conversion needed
    native()
    {
        echo "$*"
    }
fi

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# Explicitly request each of the libraries named in BOOST_LIBS.
# Use magic bash syntax to prefix each entry in BOOST_LIBS with "--with-".
BOOST_BJAM_OPTIONS="address-model=$AUTOBUILD_ADDRSIZE architecture=x86 --layout=tagged -sNO_BZIP2=1 \
                    ${BOOST_LIBS[*]/#/--with-}"

# Turn these into a bash array: it's important that all of cxxflags (which
# we're about to add) go into a single array entry.
BOOST_BJAM_OPTIONS=($BOOST_BJAM_OPTIONS)
# Append cxxflags as a single entry containing all of LL_BUILD_RELEASE.
BOOST_BJAM_OPTIONS[${#BOOST_BJAM_OPTIONS[*]}]="cxxflags=$LL_BUILD_RELEASE"

stage_lib="${stage}"/lib
stage_release="${stage_lib}"/release
mkdir -p "${stage_release}"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/debug/libz.so*.disable "${stage}"/packages/lib/release/libz.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}

# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

find_test_jamfile_dir_for()
{
    # Not every Boost library contains a libs/x/test/Jamfile.v2 file. Some
    # have libs/x/test/build/Jamfile.v2. Some have more than one test
    # subdirectory with a Jamfile. Try to be general about it.
    # You can't use bash 'read' from a pipe, though truthfully I've always
    # wished that worked. What you *can* do is read from redirected stdin, but
    # that must follow 'done'.
    while read path
    do # caller doesn't want the actual Jamfile name, just its directory
       dirname "$path"
    done < <(find libs/$1/test -name 'Jam????*' -type f -print)
    # Credit to https://stackoverflow.com/a/11100252/5533635 for the
    # < <(command) trick. Empirically, it does iterate 0 times on empty input.
}

find_test_dirs()
{
    # Pass in the libraries of interest. This shell function emits to stdout
    # the corresponding set of test directories, one per line: the specific
    # library directories containing the Jamfiles of interest. Passing each of
    # these directories to bjam should cause it to build and run that set of
    # tests.
    for blib
    do
        find_test_jamfile_dir_for "$blib"
    done
}

# conditionally run unit tests
run_tests()
{
    # This shell function wants to accept two different sets of arguments,
    # each of arbitrary length: the list of library test directories, and the
    # list of bjam arguments for each test. Since we don't have a good way to
    # do that in bash, we read library test directories from stdin, one per
    # line; command-line arguments are simply forwarded to the bjam command.
    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
        # read individual directories from stdin below
        while read testdir
        do  sep "$testdir"
            # link=static
            "${bjam}" "$testdir" "$@"
        done < /dev/stdin
    fi
    return 0
}

last_file="$(mktemp -t build-cmd.XXXXXXXX)"
trap "rm '$last_file'" EXIT
# from here on, the only references to last_file will be from Python
last_file="$(native "$last_file")"
last_time="$(python -c "import os.path; print(int(os.path.getmtime(r'$last_file')))")"
start_time="$last_time"

sep()
{
    python -c "
from __future__ import print_function
import os
import sys
import time
start = $start_time
last_file = r'$last_file'
last = int(os.path.getmtime(last_file))
now = int(time.time())
os.utime(last_file, (now, now))
def since(baseline, now):
    duration = now - baseline
    rest, secs = divmod(duration, 60)
    hours, mins = divmod(rest, 60)
    return '%2d:%02d:%02d' % (hours, mins, secs)
print('((((( %s )))))' % since(last, now), file=sys.stderr)
print(since(start, now), ' $* '.center(72, '='), file=sys.stderr)
"
}

# bjam doesn't support a -sICU_LIBPATH to point to the location
# of the icu libraries like it does for zlib. Instead, it expects
# the library files to be immediately in the ./lib directory
# and the headers to be in the ./include directory and doesn't
# provide a way to work around this. Because of this, we break
# the standard packaging layout, with the debug library files
# in ./lib/debug and the release in ./lib/release and instead
# only package the release build of icu4c in the ./lib directory.
# If a way to work around this is found, uncomment the
# corresponding blocks in the icu4c build and fix it here.

case "$AUTOBUILD_PLATFORM" in

    windows*)
        INCLUDE_PATH="$(native "${stage}"/packages/include)"
        ZLIB_RELEASE_PATH="$(native "${stage}"/packages/lib/release)"
        ICU_PATH="$(native "${stage}"/packages)"

        case "$AUTOBUILD_VSVER" in
            120)
                bootstrapver="vc12"
                bjamtoolset="msvc-12.0"
                ;;
            150)
                bootstrapver="vc141"
                bjamtoolset="msvc-14.1"
                ;;
            *)
                echo "Unrecognized AUTOBUILD_VSVER='$AUTOBUILD_VSVER'" 1>&2 ; exit 1
                ;;
        esac

        sep "bootstrap"
        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
        cmd.exe /C bootstrap.bat "$bootstrapver" || echo bootstrap failed 1>&2
        # Failure of this bootstrap.bat file may or may not produce nonzero rc
        # -- check for the program it should have built.
        if [ ! -x "$bjam.exe" ]
        then cat "bootstrap.log"
             exit 1
        fi

        # Windows build of viewer expects /Zc:wchar_t-, etc., from LL_BUILD_RELEASE.
        # Without --abbreviate-paths, some compilations fail with:
        # failed to write output file 'some\long\path\something.rsp'!
        # Without /FS, some compilations fail with:
        # fatal error C1041: cannot open program database '...\vc120.pdb';
        # if multiple CL.EXE write to the same .PDB file, please use /FS
        # BOOST_STACKTRACE_LINK (not _DYN_LINK) requests external library:
        # https://www.boost.org/doc/libs/release/doc/html/stacktrace/configuration_and_build.html
        # This helps avoid macro collisions in consuming source files:
        # https://github.com/boostorg/stacktrace/issues/76#issuecomment-489347839
        WINDOWS_BJAM_OPTIONS=("--toolset=$bjamtoolset" -j2 \
            --abbreviate-paths 
            "include=$INCLUDE_PATH" "-sICU_PATH=$ICU_PATH" \
            "-sZLIB_INCLUDE=$INCLUDE_PATH/zlib-ng" \
            cxxflags=/FS \
            cxxflags=/DBOOST_STACKTRACE_LINK \
            "${BOOST_BJAM_OPTIONS[@]}")

        RELEASE_BJAM_OPTIONS=("${WINDOWS_BJAM_OPTIONS[@]}" \
            "-sZLIB_LIBPATH=$ZLIB_RELEASE_PATH" \
            "-sZLIB_LIBRARY_PATH=$ZLIB_RELEASE_PATH" \
            "-sZLIB_NAME=zlib")
        sep "build"
        "${bjam}" link=static variant=release \
            --prefix="$(native "${stage}")" --libdir="$(native "${stage_release}")" \
            "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # Constraining Windows unit tests to link=static produces unit-test
        # link errors. While it may be possible to edit the test/Jamfile.v2
        # logic in such a way as to succeed statically, it's simpler to allow
        # dynamic linking for test purposes. However -- with dynamic linking,
        # some test executables expect to implicitly load a couple of ICU
        # DLLs. But our installed ICU doesn't even package those DLLs!
        # TODO: Does this clutter our eventual tarball, or are the extra Boost
        # DLLs in a separate build directory?
        # In any case, we still observe failures in certain libraries' unit
        # tests. Certain libraries depend on ICU; thread tests are so deeply
        # nested that even with --abbreviate-paths, the .rsp file pathname is
        # too long for Windows. Poor sad broken Windows.

        # conditionally run unit tests
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
             | \
        run_tests variant=release \
                  --prefix="$(native "${stage}")" --libdir="$(native "${stage_release}")" \
                  $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q

        # Move the libs
        mv "${stage_lib}"/*.lib "${stage_release}"

        sep "version"
        # bjam doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           /DVERSION_MACRO="$VERSION_MACRO" \
           /Fo"$(native "$stage/version.obj")" \
           /Fe"$(native "$stage/version.exe")" \
           "$(native "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done

        sep "bootstrap"
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages

        # Boost.Context and Boost.Coroutine2 now require C++14 support.
        # Without the -Wno-etc switches, clang spams the build output with
        # many hundreds of pointless warnings.
        # Building Boost.Regex without --disable-icu causes the viewer link to
        # fail for lack of an ICU library.
        DARWIN_BJAM_OPTIONS=("${BOOST_BJAM_OPTIONS[@]}" \
            "include=${stage}/packages/include" \
            "include=${stage}/packages/include/zlib-ng/" \
            "-sZLIB_INCLUDE=${stage}/packages/include/zlib-ng/" \
            cxxflags=-std=c++14 \
            cxxflags=-Wno-c99-extensions cxxflags=-Wno-variadic-macros \
            cxxflags=-Wno-unused-function cxxflags=-Wno-unused-const-variable \
            cxxflags=-Wno-unused-local-typedef \
            --disable-icu)

        RELEASE_BJAM_OPTIONS=("${DARWIN_BJAM_OPTIONS[@]}" \
            "-sZLIB_LIBPATH=${stage}/packages/lib/release")

        sep "build"
        "${bjam}" toolset=darwin variant=release "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # With Boost 1.64, skip filesystem/tests/issues -- we get:
        # error: Unable to find file or target named
        # error:     '6638-convert_aux-fails-init-global.cpp'
        # error: referred to from project at
        # error:     'libs/filesystem/test/issues'
        # regex/tests/de_fuzz depends on an external Fuzzer library:
        # ld: library not found for -lFuzzer
        # Sadly, as of Boost 1.65.1, the Stacktrace self-tests just do not
        # seem ready for prime time on Mac.
        # Bump the timeout for Boost.Thread tests because our TeamCity Mac
        # build hosts are getting a bit long in the tooth.
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/test/issues' \
             -e 'regex/test/de_fuzz' \
             -e 'stacktrace/' \
            | \
        run_tests toolset=darwin variant=release -a -q \
                  "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED" \
                  cxxflags="-DBOOST_THREAD_TEST_TIME_MS=250"

        mv "${stage_lib}"/*.a "${stage_release}"

        # populate version_file
        sep "version"
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;

    linux*)
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done

        sep "bootstrap"
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages/

        RELEASE_BOOST_BJAM_OPTIONS=(toolset=gcc "include=$stage/packages/include/zlib-ng/" \
            "-sZLIB_LIBPATH=$stage/packages/lib/release" \
            "-sZLIB_INCLUDE=${stage}\/packages/include/zlib/" \
            "${BOOST_BJAM_OPTIONS[@]}" \
            cxxflags=-std=c++11)
        sep "build"
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        mv "${stage_lib}"/libboost* "${stage_release}"

        sep "clean"
        "${bjam}" --clean

        # populate version_file
        sep "version"
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac

sep "includes and text"
mkdir -p "${stage}"/include
cp -a boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt
mkdir -p "${stage}"/docs/boost/
cp -a "$top"/README.Linden "${stage}"/docs/boost/

cd "$top"
