#!/usr/bin/env bash
# Build the pinned Peridot kernel and QCA6750 WLAN dependency set with LLVM 19.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-"$ROOT/build"}
mkdir -p "$BUILD_ROOT"
BUILD_ROOT=$(cd "$BUILD_ROOT" && pwd)
[[ "$BUILD_ROOT" != *[[:space:]]* ]] || { echo 'Build path must not contain whitespace' >&2; exit 1; }
KERNEL="$BUILD_ROOT/sm8635-kernel"
MODULES="$BUILD_ROOT/sm8635-modules"
OUT="$BUILD_ROOT/out"
DIST="$BUILD_ROOT/dist"
JOBS=${JOBS:-4}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer' >&2; exit 1; }
KERNEL_REV=db0c2edbbf0e825a9df05c2da98d1359ed6f5780
MODULES_REV=307c8a1a872a3594fd049b3d528aaa74653caf1a
for tool in git make clang-19 ld.lld-19 llvm-ar-19 llvm-nm-19 llvm-objcopy-19 llvm-strip-19 bc bison flex pahole rsync modinfo; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool (see README.md)" >&2; exit 1; }
done
clang-19 --version | head -1

checkout() {
    local url=$1 path=$2 revision=$3
    if [[ ! -d "$path" ]]; then
        git init "$path"
        git -C "$path" remote add origin "$url"
        git -C "$path" fetch --depth 1 origin "$revision"
        git -C "$path" checkout --detach FETCH_HEAD
    fi
    [[ $(git -C "$path" rev-parse HEAD) == "$revision" ]] || {
        echo "Wrong source revision in $path; use a fresh BUILD_ROOT." >&2; exit 1;
    }
}
apply_patch() {
    local path=$1 patch=$2
    if git -C "$path" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Already applied: $(basename "$patch")"
    else
        if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet; then
            echo "Unrecognized source edits in $path; use a fresh BUILD_ROOT." >&2; exit 1
        fi
        git -C "$path" apply --check "$patch"
        git -C "$path" apply "$patch"
    fi
    git -C "$path" diff --check
    git -C "$path" diff --cached --quiet
    if ! cmp -s <(git -C "$path" diff --binary) "$patch"; then
        echo "Source changes differ from the supplied patch in $path; use a fresh BUILD_ROOT." >&2
        exit 1
    fi
}
checkout https://github.com/LineageOS/android_kernel_xiaomi_sm8635.git "$KERNEL" "$KERNEL_REV"
checkout https://github.com/peridot-dev/android_kernel_xiaomi_sm8635-modules.git "$MODULES" "$MODULES_REV"
apply_patch "$KERNEL" "$ROOT/patches/0002-kernel-host-libbpf-const.patch"
apply_patch "$MODULES" "$ROOT/patches/0001-peridot-qca6750-monitor-injection.patch"
mkdir -p "$OUT" "$DIST/logs"
exec > >(tee "$DIST/logs/build.log") 2>&1
# Failed/incomplete builds must not retain an earlier success marker.
rm -f "$DIST/BUILD_SUCCESS"
export ARCH=arm64 LLVM=-19 LLVM_IAS=1
export KBUILD_BUILD_USER=peridot-builder KBUILD_BUILD_HOST=clang19
kmake() { make -C "$KERNEL" O="$OUT" TARGET_PRODUCT=peridot "$@"; }
kmake gki_defconfig
(cd "$KERNEL" && scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" \
    arch/arm64/configs/vendor/pineapple_GKI.config arch/arm64/configs/vendor/peridot_GKI.config)
"$KERNEL/scripts/config" --file "$OUT/.config" \
    -d MODULE_SIG -d MODULE_SIG_ALL -d MODULE_SIG_FORCE -d MODULE_SIG_PROTECT \
    -d TRIM_UNUSED_KSYMS
kmake olddefconfig
for option in MODULE_SIG MODULE_SIG_ALL MODULE_SIG_FORCE MODULE_SIG_PROTECT TRIM_UNUSED_KSYMS; do
    if grep -q "^CONFIG_${option}=y" "$OUT/.config"; then
        echo "Required disabled option is enabled: $option" >&2; exit 1
    fi
done
grep -qx 'CONFIG_ARCH_PINEAPPLE=y' "$OUT/.config"
kmake -j"$JOBS" Image modules

# Build dependency modules first; modpost remains strict (no unresolved-symbol bypass).
MEM="$MODULES/qcom/opensource/datarmnet-ext/mem"
IPA="$MODULES/qcom/opensource/dataipa/drivers/platform/msm"
PLATFORM="$MODULES/qcom/opensource/wlan/platform"
WLAN="$MODULES/qcom/opensource/wlan/qcacld-3.0"
kmake -j"$JOBS" M="$MEM" modules
kmake -j"$JOBS" M="$IPA" KCFLAGS="-I$MEM" KBUILD_EXTRA_SYMBOLS="$MEM/Module.symvers" modules
kmake -j"$JOBS" M="$PLATFORM" WLAN_PLATFORM_ROOT="$PLATFORM" modules
kmake -j"$JOBS" M="$WLAN" WLAN_ROOT="$WLAN" WLAN_PROFILE=qca6750 \
    DYNAMIC_SINGLE_CHIP=qca6750 MODNAME=qca_cld3_qca6750 DEVNAME=qca6750 \
    CONFIG_QCA_CLD_WLAN=m CONFIG_QCA_WIFI_ISOC=0 CONFIG_QCA_WIFI_2_0=1 \
    CONFIG_IPA_OUT_OF_TREE=y CLD_IDS=307c8a1 CMN_IDS=307c8a1 \
    KBUILD_EXTRA_SYMBOLS="$IPA/Module.symvers $PLATFORM/Module.symvers" modules

test -s "$WLAN/qca_cld3_qca6750.ko"
modinfo "$WLAN/qca_cld3_qca6750.ko" > "$DIST/wlan-modinfo.txt"
grep -q '^parm:.*injection_dp_inflight_limit:' "$DIST/wlan-modinfo.txt"
# Verify the compiled module contains the direct-DP completion hook.
llvm-nm-19 "$WLAN/qca_cld3_qca6750.ko" | grep ' T wma_injection_dp_complete$'
cp "$OUT/arch/arm64/boot/Image" "$DIST/Image"
cp "$OUT/.config" "$DIST/kernel.config"
cp "$OUT/Module.symvers" "$DIST/Module.symvers"
cp "$OUT/System.map" "$DIST/System.map"
kmake -s --no-print-directory kernelrelease > "$DIST/kernelrelease.txt"
STAGING="$BUILD_ROOT/module-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
kmake INSTALL_MOD_PATH="$STAGING" INSTALL_MOD_STRIP=1 modules_install
for module_dir in "$MEM" "$IPA" "$PLATFORM" "$WLAN"; do
    kmake M="$module_dir" INSTALL_MOD_PATH="$STAGING" INSTALL_MOD_STRIP=1 modules_install
done
while IFS= read -r -d '' module; do
    [[ -z $(modinfo -F signer "$module") ]] || { echo "Signed module: $module" >&2; exit 1; }
done < <(find "$STAGING" -name '*.ko' -print0)
# Build/source links point at host directories and do not belong on the device.
find "$STAGING/lib/modules" -type l \( -name build -o -name source \) -delete
tar -C "$STAGING" -czf "$DIST/modules.tar.gz" lib
{
    echo "Kernel: $KERNEL_REV"
    echo "Modules: $MODULES_REV"
    clang-19 --version
    ld.lld-19 --version
    sha256sum "$ROOT"/patches/*.patch
    git -C "$KERNEL" diff | sha256sum
    git -C "$MODULES" diff | sha256sum
} > "$DIST/source-revisions.txt"
(cd "$DIST" && sha256sum Image kernel.config Module.symvers System.map modules.tar.gz > SHA256SUMS)
printf 'Compilation passed. Device boot, monitor RX and over-air injection require hardware verification.\n' > "$DIST/BUILD_SUCCESS"
echo "Build complete: $DIST"
