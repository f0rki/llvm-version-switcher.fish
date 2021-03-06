#!/usr/bin/fish
# ----------------------------------------------------------------------------
# "THE BEER-WARE LICENSE" (Revision 42):
# <contact@f0rki.at> wrote this file. As long as you retain this notice you
# can do whatever you want with this stuff. If we meet some day, and you think
# this stuff is worth it, you can buy me a beer in return.
# ----------------------------------------------------------------------------

# prefered git mirror
# LLVM official git monorepo
set -g GIT_MIRROR "https://github.com/llvm/llvm-project.git"
# LLVM inofficial github mirror
#set -g GIT_MIRROR "https://github.com/llvm-mirror/"
# set to 1 if mirror is a LLVM monorepo or legacy style git/svn repos
set -g LLVM_MONO_REPO 1
# default version
set -g VERSION "master"
# default number of jobs
set -g JOBS 8
# set the compiler
set -x CC clang
set -x CXX clang++
# build command
set -g BUILD_COMMAND "ninja"
set -g BUILD_COMMAND_CMAKE "Ninja"
set -g BUILD_COMMAND_JOBS "-j"
# additional cmake options
set -g CMAKE_OPTIONS "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DLLVM_CCACHE_BUILD=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo"
# llvm projects to build
set -g LLVM_PROJECTS llvm llvm/tools/clang llvm/projects/compiler-rt
# default build dir
set -g BUILD_DIR "llvm-build-master-cmake"
# delete build dir?
set -g RM_BUILD_DIR 1

function checked_status
    if test $argv[1] -ne 0
        echo "[ERROR]" $argv[2]
        exit $argv[1]
    end
end


###### functions

function fetch_llvm

    echo "[+] git clone/pull'ing"

    if test $LLVM_MONO_REPO -eq 0

        # not a monorepo

        for proj in $LLVM_PROJECTS
            set p (basename $proj)
            set pd $p-git
            echo "[+] fetching $p"
            if test -d "./$pd";
                pushd $pd
                git pull
                checked_status $status "git pull failed"
                popd
            else
                git clone "$GIT_MIRROR/$p" $pd
                checked_status $status "git clone failed"
            end
        end

        echo "[+] symlinking if needed"

        for proj in $LLVM_PROJECTS
            set pd (basename $proj)-git
            if test -L $proj; or test -d $proj
                # all good here
                ;
            else
                echo "[+] symlinking $proj to $pd"
                ln -s (realpath ./$pd) $proj
            end
        end
    else
        # monorepo: yes
        if test -d "./llvm-project";
            pushd "./llvm-project"
            git pull
            checked_status $status "git pull failed"
            popd
        else
            git clone "$GIT_MIRROR"
            checked_status $status "git clone failed"
        end
    end
end


function switch_llvm

    set -l argc (count $argv)
    set -l v $VERSION

    if test $argc -ge 1
        set -g VERSION $argv[1]
    end

    set v $VERSION
    if echo "$VERSION" | grep "\." >/dev/null
        if test $LLVM_MONO_REPO -eq 0
            set v (echo "release_$VERSION" | sed 's/\.//g')
        else
            # monorepo uses branches like 'release/8.x' and tags like
            # llvmorg-8.x.x
            # TODO: exact version switching?
            set v "release/"(echo $VERSION | sed -E 's/\.[0-9]+//g')".x"
        end
    end

    fetch_llvm

    if test $LLVM_MONO_REPO -eq 0
        for proj in $LLVM_PROJECTS
            set p (basename $proj)
            set pd $p-git
            echo "[+] checking out latest $v for $p"

            pushd $pd
            git checkout $v
            git pull
            popd
        end
    else
        pushd "./llvm-project"
        git checkout $v
        git pull
        popd
    end

    if test $argc -ge 1; and test $argv[1] != "master"
        set -g BUILD_DIR "llvm-build-$argv[1]-cmake"
    end

    echo "[+] setting llvm-build symlink to $BUILD_DIR"
    rm llvm-build
    ln -s (realpath "$BUILD_DIR") llvm-build

end


function build_llvm

    set -l argc (count $argv)
    set -l j $JOBS
    set -l v $VERSION

    if test $argc -ge 2
        set j $argv[2]
    end

    if test $argc -ge 1
        set v $argv[1]
        echo "[+] switching to llvm version $v"
        switch_llvm $v
    else
        pushd llvm-git
        set v (git rev-parse --abbrev-ref HEAD)
        popd
        switch_llvm $v
    end

    echo "[+] Building $v with $j jobs"
    echo "[+] using build dir $BUILD_DIR"

    if not which clang >/dev/null ^/dev/null
        echo "[+] falling back to $CC/$CXX for building"
        set -x CC gcc
        set -x CXX g++
    end

    echo "[+] using $CXX for building"

    if test $RM_BUILD_DIR -eq 1
        echo "[+] cleaning previous build files"
        rm -rf "$BUILD_DIR"
        mkdir "$BUILD_DIR"
    end

    if not pushd "$BUILD_DIR"
        echo "failed to cd into $BUILD_DIR, you can try";
        echo "  ./build-llvm $argv"
        exit 1;
    end

    if test $RM_BUILD_DIR -eq 1
        if test $LLVM_MONO_REPO -eq 0

            for proj in $LLVM_PROJECTS
                set p (basename $proj)
                if test "$p" != "llvm"
                    if test "$llvm_project_list" = ""
                        set -l llvm_project_list "$p"
                    else
                        set -l llvm_project_list "$llvm_project_list;$p"
                    end
                end
            end

            set -g CMAKE_OPTIONS "$CMAKE_OPTIONS -DLLVM_ENABLE_PROJECTS='$llvm_project_list'"

            echo "[+] cmake $CMAKE_OPTIONS -G $BUILD_COMMAND_CMAKE ../llvm-project/"
            cmake $CMAKE_OPTIONS -G $BUILD_COMMAND_CMAKE ../llvm-project/
            checked_status $status "cmake failed"

        else
            echo "[+] cmake $CMAKE_OPTIONS -G $BUILD_COMMAND_CMAKE ../llvm-git/"
            cmake $CMAKE_OPTIONS -G $BUILD_COMMAND_CMAKE ../llvm-git/
            checked_status $status "cmake failed"
        end
    end

    echo "[+] starting build process: '$BUILD_COMMAND $BUILD_COMMAND_JOBS $j'"
    eval $BUILD_COMMAND $BUILD_COMMAND_JOBS $j
    if test $status -ne 0
        echo "[+] build process failed, retrying with 1 build process"
        eval $BUILD_COMMAND $BUILD_COMMAND_JOBS 1
        checked_status $status "build failed"
    end

    popd
    echo "[+] done building llvm $v"
end


#### main

set curfn (basename (status --current-filename))
set argc (count $argv)


if test $curfn = "build-llvm"
    set -g RM_BUILD_DIR 1
    build_llvm $argv
    exit $status
else if test $curfn = "switch-llvm"
    switch_llvm $argv
    exit $status
else if test $curfn = "fetch-llvm"
    fetch_llvm $argv
    exit $status
else if test $curfn = "rebuild-llvm"
    set -g RM_BUILD_DIR 0
    build_llvm $argv
    exit $status
else if test $curfn = "main.fish"
    if test $argc -eq 2
        set dst $argv[2]
        if test $argv[1] = "install"
            chmod +x (status --current-filename)
            set curfn (status --current-filename)
            ln -s (realpath $curfn) $dst/build-llvm; or true
            ln -s (realpath $curfn) $dst/rebuild-llvm; or true
            ln -s (realpath $curfn) $dst/switch-llvm; or true
            ln -s (realpath $curfn) $dst/fetch-llvm; or true
        end
    else
        echo "Install llvm build/fetch/switch from git scripts into '$PWD'? y/n"
        read choice
        if test "$choice" = "y"
            eval (status --current-filename) install $PWD
        end
    end
end
