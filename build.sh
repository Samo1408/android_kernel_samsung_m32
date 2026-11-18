#!/usr/bin/env bash
#
# 
# Samsung Galaxy M32 kernel build script
#

set -o pipefail

ROOT="$(pwd)"
OUT_DIR="$ROOT/out"

# Defaults (all can be overridden by the environment).
IS_CI="${IS_CI:-false}"
DO_CLEAN="${DO_CLEAN:-false}"
LTO="${LTO:-none}"
DEFAULT_KSU_REPO="${DEFAULT_KSU_REPO:-https://raw.githubusercontent.com/LyraVoid/FinaSU/master/kernel/setup.sh}"
# Empty means: let OriginSU select its latest stable tag.
DEFAULT_KSU_BRANCH="${DEFAULT_KSU_BRANCH:-dev}"
DEFAULT_AK3_REPO="${DEFAULT_AK3_REPO:-https://github.com/rsuntk/AnyKernel3.git}"
DEVICE="${DEVICE:-M325FV}"
IMAGE="${IMAGE:-$OUT_DIR/arch/arm64/boot/Image}"
KERNELSU="${KERNELSU:-true}"

if [ -d /rsuntk ]; then
    export CROSS_COMPILE=/rsuntk/toolchains/google/bin/aarch64-linux-android-
    export PATH=/rsuntk/toolchains/clang-12/bin:$PATH
fi

N='\033[0m'
R='\033[1;31m'
G='\033[1;32m'

export ARCH=arm64
export CLANG_TRIPLE=aarch64-linux-gnu-

MAKE_ARGS=(
    CONFIG_SECTION_MISMATCH_WARN_ONLY=y
    KCFLAGS=-w
    ARCH=arm64
)

pr_info() { echo "[+] $*"; }
pr_step() { echo "[$1 / $2] $3"; }
pr_err() { echo "[-] $*" >&2; exit 1; }
pr_invalid() { pr_err "Invalid arguments: $*"; }

usage() {
    cat <<EOF
Usage: bash $(basename "$0") <build_target> <-j | --jobs> <job_count> <defconfig>
  build_target: dirty, kernel, defconfig, clean, ak3
  -j or --jobs: number of parallel jobs

Environment:
  KERNELSU=true|false       Enable optional OriginSU integration
  DEFAULT_KSU_REPO          KazeSU legacy setup.sh URL (the script installs OriginSU)
  DEFAULT_KSU_BRANCH        Optional ref inside the OriginSU repository; leave empty for latest tag
  LTO=none|thin|full        Link-time Optimization
  LLVM=1                    Use LLVM toolchain
  LLVM_IAS=1                Use LLVM integrated assembler
  DO_CLEAN=true             Clean after a successful local build
  IS_CI=true                CI mode (disables post-build cleanup)
EOF
    exit 2
}

setconfig() {
    local action="$1"
    local symbol="$2"
    local config_file="$OUT_DIR/.config"

    [ -x "$ROOT/scripts/config" ] || chmod +x "$ROOT/scripts/config" 2>/dev/null || true
    [ -f "$ROOT/scripts/config" ] || pr_err "scripts/config not found."
    [ -f "$config_file" ] || pr_err "Configuration file not found: $config_file"

    case "$action" in
        enable|disable) ;;
        *) pr_err "Invalid config action: $action" ;;
    esac

    pr_info "$([ "$action" = enable ] && echo Enabling || echo Disabling) CONFIG_${symbol}"
    "$ROOT/scripts/config" --file "$config_file" "--$action" "CONFIG_${symbol}" ||
        pr_err "Unable to $action CONFIG_${symbol}"
}

clone_ak3() {
    if [ ! -d "$ROOT/AnyKernel3" ]; then
        git clone --depth=1 "$DEFAULT_AK3_REPO" "$ROOT/AnyKernel3" ||
            pr_err "Unable to clone AnyKernel3 from $DEFAULT_AK3_REPO"
    fi
    [ -d "$ROOT/AnyKernel3" ] || pr_err "AnyKernel3 directory is missing."
    rm -rf "$ROOT/AnyKernel3/.git"
}


prepare_ksu_disabled_stub() {
    local ksu_dir="$ROOT/drivers/kernelsu"
    local ksu_kconfig="$ksu_dir/Kconfig"

    # Linux 4.14 Kconfig supports "source", not an optional-source directive.
    # Provide a hidden CONFIG_KSU=n placeholder only for builds without OriginSU.
    if [ -L "$ksu_dir" ] && [ ! -e "$ksu_kconfig" ]; then
        rm -f "$ksu_dir"
    fi

    if [ ! -f "$ksu_kconfig" ]; then
        [ -d "$ksu_dir" ] || mkdir -p "$ksu_dir"
        cat > "$ksu_kconfig" <<'EOF'
# Temporary placeholder for builds with OriginSU disabled.
config KSU
    bool
    default n
EOF
        pr_info "FinaSU disabled: temporary CONFIG_KSU=n Kconfig placeholder created."
    fi
}

install_origin_su() {
    pr_info "KSU option enabled: setting up FinaSU"

    # Allow switching from a previous KSU-disabled build in the same worktree.
    if [ -f "$ROOT/drivers/kernelsu/Kconfig" ] &&
       grep -q "Temporary placeholder for builds with OriginSU disabled" "$ROOT/drivers/kernelsu/Kconfig"; then
        rm -rf "$ROOT/drivers/kernelsu"
    fi

    command -v curl >/dev/null 2>&1 || pr_err "curl is required to install FinaSU."
    [ -n "$DEFAULT_KSU_REPO" ] || pr_err "DEFAULT_KSU_REPO is empty."

    # With submodules:false, Git may leave an empty KernelSU/ directory
    # for the KernelSU submodule declared in .gitmodules. The upstream
    # setup.sh checks only -d, so that empty directory would make it skip
    # cloning and Git commands would accidentally run in the parent kernel repo.
    if [ -d "$ROOT/FinaSU" ] && [ ! -e "$ROOT/FinaSU/.git" ]; then
        if [ -z "$(find "$ROOT/FinaSU" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            rmdir "$ROOT/FinaSU" || pr_err "Unable to remove empty FinaSU submodule placeholder."
            pr_info "Removed empty FinaSU submodule placeholder before FinaSU setup."
        else
            pr_err "FinaSU/ exists but is not a Git checkout and is not empty; refusing to overwrite it."
        fi
    fi

    # Do not pass 'legacy' here: that names the branch containing this
    # KazeSU setup script, not a ref in the OriginSU repository it clones.
    if [ -n "$DEFAULT_KSU_BRANCH" ]; then
        curl -fL --retry 3 --retry-delay 2 "$DEFAULT_KSU_REPO" |
            bash -s -- "$DEFAULT_KSU_BRANCH" ||
            pr_err "OriginSU setup failed for ref '$DEFAULT_KSU_BRANCH'."
    else
        curl -fL --retry 3 --retry-delay 2 "$DEFAULT_KSU_REPO" |
            bash -s -- ||
            pr_err "OriginSU setup failed."
    fi

    [ -d "$ROOT/FinaSU" ] || pr_err "FinaSU setup did not create FinaSU/."
    [ -e "$ROOT/drivers/kernelsu" ] || pr_err "FinaSU did not create drivers/kernelsu."
    [ -f "$ROOT/drivers/kernelsu/Kconfig" ] ||
        pr_err "FinaSU integration is incomplete: drivers/kernelsu/Kconfig is missing."

    # Linux 4.14 Kconfig rejects an endmenu in drivers/Kconfig when the
    # sourced OriginSU Kconfig opens its own menu inside that parent menu.
    # Keep the OriginSU menu self-contained by sourcing it after the
    # Device Drivers menu has been closed. Remove duplicates first so this
    # remains safe on repeated builds.
    if grep -Fq 'source "drivers/kernelsu/Kconfig"' "$ROOT/drivers/Kconfig"; then
        sed -i '\|^source "drivers/kernelsu/Kconfig"[[:space:]]*$|d' "$ROOT/drivers/Kconfig"
    fi
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$ROOT/drivers/Kconfig"
    tail -n 4 "$ROOT/drivers/Kconfig"

    pr_info "FinaSU integration verified (Kconfig source placed outside Device Drivers menu)."
}

gen_getutsrelease() {
    if [ ! -e "$ROOT/utsrelease.c" ]; then
        cat > "$ROOT/utsrelease.c" <<'EOF'
#include <stdio.h>
#ifdef __OUT__
#include "out/include/generated/utsrelease.h"
#else
#include "include/generated/utsrelease.h"
#endif
char utsrelease[] = UTS_RELEASE;
int main(void) {
    printf("%s\n", utsrelease);
    return 0;
}
EOF
    fi
}

pr_post_build() {
    local status="$1"
    echo
    if [ "$status" = failed ]; then
        echo -e "${R}#### Failed to build target ($BUILD_TARGET) ####${N}"
        return 1
    fi

    echo -e "${G}#### Build completed at $(date) ####${N}"
    echo
    echo "======================================================="
    if [ -f "$IMAGE" ]; then
        strings "$IMAGE" | grep -m1 "Linux version" || true
    else
        echo "Image not found: $IMAGE"
        return 1
    fi
    echo "======================================================="
}

post_build_clean() {
    if [ -d "$ROOT/AnyKernel3" ]; then
        rm -f "$ROOT/AnyKernel3/Image"
        rm -f "$ROOT"/AnyKernel3/modules/vendor/lib/modules/*.ko
        mkdir -p "$ROOT/AnyKernel3/modules/vendor/lib/modules"
        echo "stub" > "$ROOT/AnyKernel3/modules/vendor/lib/modules/stub"
    fi
    rm -f "$ROOT/getutsrel" "$ROOT/utsrelease.c"
    rm -rf "$OUT_DIR"
    make -C "$ROOT" clean
    make -C "$ROOT" mrproper
}

post_build() {
    local gitsha date_stamp zip_fmt utsrelease
    local ak3="$ROOT/AnyKernel3"

    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        gitsha="$(git -C "$ROOT" rev-parse --short HEAD)"
    else
        gitsha="localbuild"
    fi

    date_stamp="$(date +'%Y%m%d%H%M%S')"
    zip_fmt="AnyKernel3-$(make -s -C "$ROOT" kernelversion)-${DEVICE}_${gitsha}-${date_stamp}"

    clone_ak3
    pr_info "Creating AnyKernel3 package"

    gen_getutsrelease
    gcc -D__OUT__ "$ROOT/utsrelease.c" -o "$ROOT/getutsrel" ||
        pr_err "Unable to compile utsrelease helper."
    utsrelease="$("$ROOT/getutsrel")"
    [ -n "$utsrelease" ] || pr_err "Unable to determine UTS_RELEASE."

    if grep -q '^kernel.string=' "$ak3/anykernel.sh"; then
        sed -i "s/^kernel\.string=.*/kernel.string=$utsrelease/" "$ak3/anykernel.sh"
    else
        printf '\nkernel.string=%s\n' "$utsrelease" >> "$ak3/anykernel.sh"
    fi

    if grep -q '^BLOCK=' "$ak3/anykernel.sh"; then
        sed -i 's#^BLOCK=.*#BLOCK=/dev/block/platform/bootdevice/by-name/boot;#' "$ak3/anykernel.sh"
    else
        printf '\nBLOCK=/dev/block/platform/bootdevice/by-name/boot;\n' >> "$ak3/anykernel.sh"
    fi

    cp "$IMAGE" "$ak3/Image" || pr_err "Unable to copy kernel Image into AnyKernel3."
    (
        cd "$ak3"
        zip -r9 "$ROOT/${zip_fmt}.zip" . ||
            pr_err "Unable to create AnyKernel3 ZIP."
    )

    [ -s "$ROOT/${zip_fmt}.zip" ] || pr_err "AnyKernel3 ZIP was not created."
    pr_info "AnyKernel3 package created: ${zip_fmt}.zip"

    if [ "$IS_CI" != true ] && [ "$DO_CLEAN" = true ]; then
        pr_info "Local post-build cleanup enabled."
        post_build_clean
    fi
}

handle_lto() {
    case "$LTO" in
        none)
            pr_info "LTO not set."
            ;;
        thin)
            pr_info "LTO: Thin"
            setconfig disable LTO_NONE
            setconfig enable LTO
            setconfig enable THINLTO
            setconfig enable LTO_CLANG
            setconfig enable ARCH_SUPPORTS_LTO_CLANG
            setconfig enable ARCH_SUPPORTS_THINLTO
            ;;
        full)
            pr_info "LTO: Full"
            setconfig disable LTO_NONE
            setconfig enable LTO
            setconfig disable THINLTO
            setconfig enable LTO_CLANG
            setconfig enable ARCH_SUPPORTS_LTO_CLANG
            setconfig enable ARCH_SUPPORTS_THINLTO
            ;;
        *)
            pr_err "Unsupported LTO value '$LTO'. Use none, thin, or full."
            ;;
    esac
}

# Special targets that do not use the normal four-argument build interface.
BUILD_TARGET="${1:-}"
case "$BUILD_TARGET" in
    clean)
        [ "$#" -eq 1 ] || pr_err "clean accepts no additional arguments."
        pr_info "Cleaning build directories."
        if [ -d "$OUT_DIR" ]; then
            rm -rf "$OUT_DIR"
        elif [ -f "$ROOT/.config" ]; then
            make -C "$ROOT" clean || pr_err "make clean failed."
            make -C "$ROOT" mrproper || pr_err "make mrproper failed."
        else
            pr_err "No build output or root .config found; nothing to clean."
        fi
        pr_info "Clean completed."
        exit 0
        ;;
    ak3)
        [ "$#" -eq 1 ] || pr_err "ak3 accepts no additional arguments."
        clone_ak3
        exit 0
        ;;
    dirty)
        [ "$#" -eq 3 ] || usage
        FIRST_JOB="$2"
        ALLOC_JOB="$3"
        [[ "$FIRST_JOB" == -j || "$FIRST_JOB" == --jobs ]] || pr_invalid "$FIRST_JOB"
        [[ "$ALLOC_JOB" =~ ^[1-9][0-9]*$ ]] || pr_invalid "$ALLOC_JOB"

        if [ "$KERNELSU" = true ]; then
            install_origin_su
            [ -f "$OUT_DIR/.config" ] && setconfig enable KSU
        else
            prepare_ksu_disabled_stub
            [ -f "$OUT_DIR/.config" ] && setconfig disable KSU
        fi

        pr_info "Starting dirty build"
        make -j"$ALLOC_JOB" -C "$ROOT" O="$OUT_DIR" "${MAKE_ARGS[@]}" ||
            pr_err "Dirty build failed."
        [ -f "$IMAGE" ] || pr_err "Dirty build finished without producing Image."
        BUILD_TARGET=dirty
        pr_post_build completed
        exit 0
        ;;
    kernel|defconfig)
        [ "$#" -eq 4 ] || usage
        ;;
    *)
        usage
        ;;
esac

FIRST_JOB="$2"
ALLOC_JOB="$3"
BUILD_DEFCONFIG="$4"

[[ "$FIRST_JOB" == -j || "$FIRST_JOB" == --jobs ]] || pr_invalid "$FIRST_JOB"
[[ "$ALLOC_JOB" =~ ^[1-9][0-9]*$ ]] || pr_invalid "$ALLOC_JOB"
[ -n "$BUILD_DEFCONFIG" ] || pr_invalid "missing defconfig"

if [ "${LLVM:-0}" = 1 ]; then
    MAKE_ARGS+=(LLVM=1)
    export LLVM=1
    if [ "${LLVM_IAS:-0}" = 1 ]; then
        MAKE_ARGS+=(LLVM_IAS=1)
        export LLVM_IAS=1
    fi
fi

# OriginSU is installed only when the GitHub Actions KSU input is enabled.
if [ "$KERNELSU" = true ]; then
    install_origin_su
else
    prepare_ksu_disabled_stub
    pr_info "FinaSU is disabled; building without KSU."
fi

pr_step 1 3 "Starting build with Rissu's build script"
echo
echo "======================================================="
echo "Host Arch: $(uname -m)"
echo "Host Kernel: $(uname -r)"
echo "Host GNUMake: $(make -v | grep -m1 'GNU Make' || true)"
echo "Kernel builder user: ${KBUILD_BUILD_USER:-$(whoami)}"
echo "Kernel builder host: ${KBUILD_BUILD_HOST:-$(uname -n)}"
echo
echo "Linux version: $(make -s -C "$ROOT" kernelversion)"
echo "Build date: $(date)"
echo "Build target: $BUILD_TARGET"
echo "Build arch: $ARCH"
echo "Target Defconfig: $BUILD_DEFCONFIG"
echo "Allocated core(s): $ALLOC_JOB"
echo "LTO: $LTO"
echo "LLVM: ${LLVM:-0}"
echo "LLVM_IAS: ${LLVM_IAS:-0}"
echo "FinaSU: $KERNELSU"
echo "======================================================="

pr_step 2 3 "Configuring and building $BUILD_TARGET"

make -j"$ALLOC_JOB" -C "$ROOT" O="$OUT_DIR" "${MAKE_ARGS[@]}" "$BUILD_DEFCONFIG" ||
    pr_err "Defconfig '$BUILD_DEFCONFIG' failed."
[ -f "$OUT_DIR/.config" ] || pr_err "Defconfig completed without creating $OUT_DIR/.config."

if [ "$KERNELSU" = true ]; then
    setconfig enable KSU
else
    setconfig disable KSU
fi

handle_lto

if [ "$BUILD_TARGET" = defconfig ]; then
    pr_info "Defconfig generated successfully: $OUT_DIR/.config"
    exit 0
fi

make -j"$ALLOC_JOB" -C "$ROOT" O="$OUT_DIR" "${MAKE_ARGS[@]}" ||
    pr_err "Kernel compilation failed."

[ -f "$IMAGE" ] || pr_err "Build command returned success but Image is missing."
pr_post_build completed || pr_err "Post-build image validation failed."
post_build
pr_step 3 3 "Build script ended."
