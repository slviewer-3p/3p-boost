#!/bin/bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
set -x
# make errors fatal
set -e
# error on undefined environment variables
set -u

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$BOOST_SOURCE_DIR/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

if [ -z "$AUTOBUILD" ] ; then 
    fail
fi

# Libraries on which we depend - please keep alphabetized for maintenance
BOOST_LIBS=(context coroutine date_time filesystem iostreams program_options \
            regex signals system thread)

# Optionally use this function in a platform build to SUPPRESS running unit
# tests on one or more specific libraries: sadly, it happens that some
# libraries we care about might fail their unit tests on a particular platform
# for a particular Boost release.
# Usage: suppress_tests date_time regex
function suppress_tests {
  set +x
  for lib
  do for ((i=0; i<${#BOOST_LIBS[@]}; ++i))
     do if [[ "${BOOST_LIBS[$i]}" == "$lib" ]]
        then unset BOOST_LIBS[$i]
             # From -x trace output, it appears that the above 'unset' command
             # doesn't immediately close the gaps in the BOOST_LIBS array. In
             # fact it seems that although the count ${#BOOST_LIBS[@]} is
             # decremented, there's a hole at [$i], and subsequent elements
             # remain at their original subscripts. Reset the array: remove
             # any such holes.
             BOOST_LIBS=("${BOOST_LIBS[@]}")
             break
        fi
     done
  done
  echo "BOOST_LIBS=${BOOST_LIBS[*]}"
  set -x
}

BOOST_BUILD_SPAM="-d2 -d+4"             # -d0 is quiet, "-d2 -d+4" allows compilation to be examined

top="$(pwd)"
cd "$BOOST_SOURCE_DIR"
bjam="$(pwd)/bjam"
stage="$(pwd)/stage"

[ -f "$stage"/packages/include/zlib/zlib.h ] || fail "You haven't installed the zlib package yet."
                                                     
if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
    # Bjam doesn't know about cygwin paths, so convert them!
else
    autobuild="$AUTOBUILD"
fi

# load autobuild provided shell functions and variables
set +x
eval "$("$autobuild" source_environment)"
set -x

# pull in LL_BUILD with platform-appropriate compiler switches
set_build_variables convenience Release

# Explicitly request each of the libraries named in BOOST_LIBS.
# Use magic bash syntax to prefix each entry in BOOST_LIBS with "--with-".
BOOST_BJAM_OPTIONS="address-model=$AUTOBUILD_ADDRSIZE architecture=x86 --layout=tagged -sNO_BZIP2=1 \
                    ${BOOST_LIBS[*]/#/--with-}"

# Turn these into a bash array: it's important that all of cxxflags (which
# we're about to add) go into a single array entry.
BOOST_BJAM_OPTIONS=($BOOST_BJAM_OPTIONS)
# Append cxxflags as a single entry containing all of LL_BUILD.
BOOST_BJAM_OPTIONS[${#BOOST_BJAM_OPTIONS[*]}]="cxxflags=$LL_BUILD"

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
        INCLUDE_PATH="$(cygpath -m "${stage}"/packages/include)"
        ZLIB_RELEASE_PATH="$(cygpath -m "${stage}"/packages/lib/release)"
        ICU_PATH="$(cygpath -m "${stage}"/packages)"

        case "$AUTOBUILD_VSVER" in
            120)
                bootstrapver="vc12"
                bjamtoolset="msvc-12.0"
                ;;
            *)
                fail "Unrecognized AUTOBUILD_VSVER='$AUTOBUILD_VSVER'"
                ;;
        esac

        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
        cmd.exe /C bootstrap.bat "$bootstrapver"

        # Windows build of viewer expects /Zc:wchar_t-, etc., from LL_BUILD.
        # Without --abbreviate-paths, some compilations fail with:
        # failed to write output file 'some\long\path\something.rsp'!
        # Without /FS, some compilations fail with:
        # fatal error C1041: cannot open program database '...\vc120.pdb';
        # if multiple CL.EXE write to the same .PDB file, please use /FS
        WINDOWS_BJAM_OPTIONS=("--toolset=$bjamtoolset" -j2 \
            --abbreviate-paths 
            "include=$INCLUDE_PATH" "-sICU_PATH=$ICU_PATH" \
            "-sZLIB_INCLUDE=$INCLUDE_PATH/zlib" \
            cxxflags=/FS \
            "${BOOST_BJAM_OPTIONS[@]}")

        RELEASE_BJAM_OPTIONS=("${WINDOWS_BJAM_OPTIONS[@]}" \
            "-sZLIB_LIBPATH=$ZLIB_RELEASE_PATH" \
            "-sZLIB_LIBRARY_PATH=$ZLIB_RELEASE_PATH" \
            "-sZLIB_NAME=zlib")
        "${bjam}" link=static variant=release \
            --prefix="${stage}" --libdir="${stage_release}" \
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
        suppress_tests date_time filesystem iostreams regex thread

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"$blib"/test
                    # link=static
                    "${bjam}" variant=release \
                        --prefix="${stage}" --libdir="${stage_release}" \
                        $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q
                popd
            done
        fi

        # Move the libs
        mv "${stage_lib}"/*.lib "${stage_release}"

        # bjam doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           /DVERSION_MACRO="$VERSION_MACRO" \
           /Fo"$(cygpath -w "$stage/version.obj")" \
           /Fe"$(cygpath -w "$stage/version.exe")" \
           "$(cygpath -w "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        suppress_tests date_time

        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done
            
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages

        # Without the -Wno-etc switches, clang spams the build output with
        # many hundreds of pointless warnings.
        DARWIN_BJAM_OPTIONS=("${BOOST_BJAM_OPTIONS[@]}" \
            "include=${stage}/packages/include" \
            "include=${stage}/packages/include/zlib/" \
            "-sZLIB_INCLUDE=${stage}/packages/include/zlib/" \
            cxxflags=-Wno-c99-extensions cxxflags=-Wno-variadic-macros \
            cxxflags=-Wno-unused-function cxxflags=-Wno-unused-const-variable)

        RELEASE_BJAM_OPTIONS=("${DARWIN_BJAM_OPTIONS[@]}" \
            "-sZLIB_LIBPATH=${stage}/packages/lib/release")

        "${bjam}" toolset=darwin variant=release "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" toolset=darwin variant=release -a -q \
                        "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM
                popd
            done
        fi

        mv "${stage_lib}"/*.a "${stage_release}"

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;

    linux*)
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        suppress_tests date_time
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done
            
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages/

        RELEASE_BOOST_BJAM_OPTIONS=(toolset=gcc-4.6 "include=$stage/packages/include/zlib/" \
            "-sZLIB_LIBPATH=$stage/packages/lib/release" \
            "-sZLIB_INCLUDE=${stage}\/packages/include/zlib/" \
            "${BOOST_BJAM_OPTIONS[@]}")
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" variant=release -a -q \
                        --prefix="${stage}" --libdir="${stage}"/lib/release \
                        "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM
                popd
            done
        fi

        mv "${stage_lib}"/libboost* "${stage_release}"

        "${bjam}" --clean

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac
    
mkdir -p "${stage}"/include
cp -a boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt
mkdir -p "${stage}"/docs/boost/
cp -a "$top"/README.Linden "${stage}"/docs/boost/

cd "$top"

pass
