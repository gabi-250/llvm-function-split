#!/bin/bash

# This script applies the splitter to the sqlite3 and testfixture binaries (see
# `BINARIES`) and runs the test suite on CHERI platforms.
#
# Note: this expects `CHERI` to be set to the directory where your CHERI SDK is
# installed (e.g. `~/cheri/output/morello-sdk`).
#
# Usage:
#   * To run the tests on a remote machine:
#     ```
#     CHERI=~/cheri/output/morello-sdk SSHPORT=<SSH port> RUNHOST=<IP addr> RUNUSER=<remote user> RUNDIR=<remote user home> ./sqlite.sh
#     ```
#   * To run against a locally running QEMU instance:
#     ```
#     CHERI=~/cheri/output/morello-sdk SSHPORT=<qemu ssh port> RUNDIR=/root RUNUSER=root ./sqlite.sh
#     ```
#
# NOTE: the sqlite tests (quicktest, tcltest) fail with `CHERI protection
# violation` on purecap morello (this could be an issue with the CheriBSD
# sqlite3 port, as the tests raise SIGPROT even if we don't apply the splitter
# to the `testfixture` binary):
# https://gist.github.com/gabi-250/3d362b63062265d793bbaca795d71d3b
#
# See also this backtrace: https://gist.github.com/gabi-250/4dceaf7dec843799af6c9ee39f7bbe65
#
# NOTE: once the root cause of the SIGPROTs is identified and fixed, this script
# can be integrated into the main test script that runs in CI (tests/run_tests.sh).

set -eou pipefail

readonly REPODIR=$(pwd)
readonly SPLITTER=$REPODIR/split-llvm-extract
readonly GET_BC=$HOME/go/bin/get-bc
readonly GCLANG=$HOME/go/bin/gclang

build_splitter() {
    make \
        -j"$(nproc)" \
        CXX=$CHERI/bin/clang++ \
        LLVM_CONFIG="$CHERI"/bin/llvm-config \
        LLVM_LINK="$CHERI"/bin/llvm-link \
        LLVM_EXTRACT="$CHERI"/bin/llvm-extract \
        split-llvm-extract
}

build_sqlite() {
    if ! [ -d sqlite ]; then
        git clone https://github.com/CTSRD-CHERI/sqlite
    fi

    pushd sqlite
    # As described in http://repo.or.cz/w/sqlite.git
    ./create-fossil-manifest
    mkdir -p build
    pushd build

    cp ../../tcl8.6.12/unix/build/libtcl8.6.so .

    CC=$GCLANG LLVM_COMPILER_PATH=$CHERI/bin LD_LIBRARY_PATH=$CHERI/lib/ CFLAGS="--config cheribsd-morello-purecap.cfg" ../configure \
        --with-pic \
        --disable-load-extension \
        --disable-editline \
        --host=aarch64-unknown-freebsd13 \
        --target=aarch64-unknown-freebsd13 \
        --build=x86_64-pc-linux-gnu \
        --libdir=/usr/local/morello-purecap/lib \

    sed -ie "s#LIBTCL = -L/usr/lib/x86_64-linux-gnu -ltcl8.6#LIBTCL = -L. -ltcl8.6#" Makefile
    # We could temporarily disable the tests that trigger SIGPROT on CHERI,
    # e.g.:
    #sed -ie '/{ "sqlite3_create_aggregate",      (Tcl_CmdProc\*)test_create_aggregate }/d' ../src/test1.c

    # TODO: The cfDeviceCharacteristics function of test6.c is not extracted
    # correctly:
    # ```
    #    gabi@cheribsd-purecap:~/sqlite/build $ LD_LIBRARY_PATH=out-testfixture/ time make tcltest
    #    ./testfixture /home/gabi/sqlite/build/../test/veryquick.test --verbose=file --output=test-out.txt
    #    ld-elf.so.1: out-testfixture//lib_cfDeviceCharacteristics.so: Could not find symbol g.1014
    #    *** Error code 1
    #
    #    Stop.
    #    make: stopped in /usr/home/gabi/sqlite/build
    #            5.14 real         5.05 user         0.08 sys
    # ```
    #sed -ie '\#\$(TOP)/src/test6.c#d' Makefile
    #sed -ie '/Sqlitetest6_Init/d' ../src/test_tclsh.c

    LLVM_COMPILER_PATH=$CHERI/bin GLLVM_OBJCOPY=$CHERI/bin/objcopy make -j$(nproc) BCC=$GCLANG
    LLVM_COMPILER_PATH=$CHERI/bin LD_LIBRARY_PATH=$CHERI/lib/ GLLVM_OBJCOPY=$CHERI/bin/objcopy CFLAGS="--config cheribsd-morello-purecap.cfg" make testfixture -j$(nproc) BCC=$GCLANG

    sed -ie "s#/home/$USER/llvm-function-split#$RUNDIR#" Makefile

    popd
    popd
}

# TODO: find a more elegant way to apply these patches.
apply_tcl_cheri_patches() {
    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/patch-generic-tclPort.h
    patch -p0 < patch-generic-tclPort.h

    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/patch-unix-Makefile.in
    patch -p0 < patch-unix-Makefile.in

    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/patch-unix-configure
    patch -p0 < patch-unix-configure

    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/patch-unix-installManPage
    patch -p0 < patch-unix-installManPage

    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/patch-unix-tclUnixInit.c
    patch -p0 < patch-unix-tclUnixInit.c

    wget https://raw.githubusercontent.com/CTSRD-CHERI/cheribsd-ports/main/lang/tcl86/files/cheribsd.patch
    patch -p0 < cheribsd.patch
}

build_tcl() {
    curl -O -L https://downloads.sourceforge.net/project/tcl/Tcl/8.6.12/tcl8.6.12-src.tar.gz
    tar -xvf tcl8.6.12-src.tar.gz
    pushd tcl8.6.12
    apply_tcl_cheri_patches
    pushd unix
    mkdir -p build
    pushd build

    CC=$GCLANG LLVM_COMPILER_PATH=$CHERI/bin CFLAGS="--config cheribsd-morello-purecap.cfg" ../configure \
        --host=aarch64-unknown-freebsd13 \
        --target=aarch64-unknown-freebsd13 \
        --build=x86_64-pc-linux-gnu \
        --libdir=/usr/local/morello-purecap/lib \

    LLVM_COMPILER_PATH=$CHERI/bin GLLVM_OBJCOPY=$CHERI/bin/objcopy make libtcl8.6.so

    popd
    popd
    popd
}

split_binary() {
    binary=$1
    pushd sqlite/build
    # Extract bitcode from the binary
    LLVM_COMPILER_PATH=$CHERI/bin $GET_BC $binary
    LLVM_EXTRACT=$CHERI/bin/llvm-extract LD_LIBRARY_PATH=$CHERI/lib/ $SPLITTER $binary.bc -o out-$binary
    cp $REPODIR/tests/Makefile-sqlite out-$binary/Makefile
    pushd out-$binary
    CC=$CHERI/bin/clang CFLAGS="--config cheribsd-morello-purecap.cfg" make
    popd
    # Replace the original binary with a symlink to the "joined" split one (this
    # enables us to use the existing test suite without having to modify it).
    mv $binary $binary.original
    ln -f -s ./out-$binary/joined $binary
    # Place libtcl next to the other libraries this binary links against
    ln -f -s ./libtcl8.6.so out-$binary/
    popd
}

run_cheri_tests() {
    make copy-exec-tests -f tests/Makefile-sqlite
}

build_splitter
build_tcl
build_sqlite

# sqlite3 binaries to split
BINARIES=("testfixture")
#BINARIES=("sqlite3" "testfixture")

for binary in "${BINARIES[@]}"; do
     split_binary $binary
done

run_cheri_tests
