#!/usr/bin/env bash

# Poco F6 / Peridot
# Kernel and QCA6750 WLAN build using LLVM 19.
# Requires the existing kernel and WLAN patch files.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-"$ROOT/build"}"
mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"

if [[ "$BUILD_ROOT" =~ [[:space:]] ]]; then
    echo "ERROR: BUILD_ROOT must not contain whitespace." >&2
    exit 1
fi

KERNEL="$BUILD_ROOT/sm8635-kernel"
MODULES="$BUILD_ROOT/sm8635-modules"
OUT="$BUILD_ROOT/out"
DIST="$BUILD_ROOT/dist"
STAGING="$BUILD_ROOT/module-staging"

JOBS="${JOBS:-4}"

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: JOBS must be a positive integer." >&2
    exit 1
fi

# Pinned source revisions.
KERNEL_REV="db0c2edbbf0e825a9df05c2da98d1359ed6f5780"
MODULES_REV="307c8a1a872a3594fd049b3d528aaa74653caf1a"

KERNEL_URL="https://github.com/LineageOS/android_kernel_xiaomi_sm8635.git"
MODULES_URL="https://github.com/peridot-dev/android_kernel_xiaomi_sm8635-modules.git"

KERNEL_PATCH="$ROOT/patches/0002-kernel-host-libbpf-const.patch"
WLAN_PATCH="$ROOT/patches/0001-peridot-qca6750-monitor-injection.patch"

# Fail early if tools or patches are missing.
for tool in \
    git make clang-19 ld.lld-19 \
    llvm-ar-19 llvm-nm-19 llvm-objcopy-19 llvm-strip-19 \
    bc bison flex pahole rsync modinfo sha256sum
do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Missing prerequisite: $tool" >&2
        exit 1
    fi
done

for patch in "$KERNEL_PATCH" "$WLAN_PATCH"; do
    if [[ ! -s "$patch" ]]; then
        echo "ERROR: Missing or empty patch: $patch" >&2
        exit 1
    fi
done

clang-19 --version
ld.lld-19 --version

mkdir -p "$DIST/logs"

# Log all build output.
exec > >(tee "$DIST/logs/build.log") 2>&1

# Remove stale success and checksum markers before starting.
rm -f "$DIST/BUILD_SUCCESS" "$DIST/SHA256SUMS"

# ------------------------------------------------------------
# Source checkout
# ------------------------------------------------------------

checkout() {
    local url="$1"
    local path="$2"
    local revision="$3"

    if [[ ! -d "$path/.git" ]]; then
        if [[ -e "$path" ]]; then
            echo "ERROR: Existing directory is not a Git checkout: $path" >&2
            exit 1
        fi

        mkdir -p "$(dirname "$path")"
        git init "$path"
        git -C "$path" remote add origin "$url"
    fi

    if ! git -C "$path" remote get-url origin >/dev/null 2>&1; then
        echo "ERROR: No Git origin configured in $path" >&2
        exit 1
    fi

    git -C "$path" fetch --depth 1 origin "$revision"
    git -C "$path" checkout --detach FETCH_HEAD

    local actual
    actual="$(git -C "$path" rev-parse HEAD)"

    if [[ "$actual" != "$revision" ]]; then
        echo "ERROR: Wrong source revision in $path" >&2
        echo "Expected: $revision" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi

    echo "Checked out $path at $actual"
}

# ------------------------------------------------------------
# Patch application
# ------------------------------------------------------------

apply_patch() {
    local path="$1"
    local patch_file="$2"

    echo "Checking patch: $patch_file"

    # Recognize an already-applied complete patch.
    if git -C "$path" apply --reverse --check "$patch_file" \
        >/dev/null 2>&1; then

        echo "Patch already applied: $(basename "$patch_file")"

    else
        # Do not silently mix unrelated edits with this build.
        if ! git -C "$path" diff --quiet ||
           ! git -C "$path" diff --cached --quiet; then

            echo "ERROR: Unrecognized source edits in $path" >&2
            echo "Use a fresh BUILD_ROOT to avoid mixing patches." >&2
            exit 1
        fi

        # Verify the entire patch applies before modifying anything.
        if ! git -C "$path" apply --check "$patch_file"; then
            echo "ERROR: Patch does not apply cleanly: $patch_file" >&2
            exit 1
        fi

        git -C "$path" apply "$patch_file"

        echo "Applied patch: $(basename "$patch_file")"
    fi

    # Reject whitespace errors and incomplete patch application.
    git -C "$path" diff --check

    if ! git -C "$path" diff --quiet; then
        echo "Patch verification passed."
    else
        echo "ERROR: Patch produced no source changes." >&2
        exit 1
    fi
}

checkout "$KERNEL_URL" "$KERNEL" "$KERNEL_REV"
checkout "$MODULES_URL" "$MODULES" "$MODULES_REV"

apply_patch "$KERNEL" "$KERNEL_PATCH"
apply_patch "$MODULES" "$WLAN_PATCH"

# ------------------------------------------------------------
# Build environment
# ------------------------------------------------------------

export ARCH=arm64
export LLVM=-19
export LLVM_IAS=1

export KBUILD_BUILD_USER=peridot-builder
export KBUILD_BUILD_HOST=clang19

kmake() {
    make -C "$KERNEL" \
        O="$OUT" \
        TARGET_PRODUCT=peridot \
        "$@"
}

mkdir -p "$OUT"

# ------------------------------------------------------------
# Kernel configuration
# ------------------------------------------------------------

echo "Configuring kernel..."

kmake gki_defconfig

(
    cd "$KERNEL"

    scripts/kconfig/merge_config.sh \
        -m \
        -O "$OUT" \
        "$OUT/.config" \
        arch/arm64/configs/vendor/pineapple_GKI.config \
        arch/arm64/configs/vendor/peridot_GKI.config
)

# Disable module signing and symbol trimming.
"$KERNEL/scripts/config" --file "$OUT/.config" \
    -d MODULE_SIG \
    -d MODULE_SIG_ALL \
    -d MODULE_SIG_FORCE \
    -d MODULE_SIG_PROTECT \
    -d TRIM_UNUSED_KSYMS

kmake olddefconfig

# Validate final configuration after olddefconfig.
require_config() {
    local symbol="$1"
    local expected="$2"

    if ! grep -qx "$expected" "$OUT/.config"; then
        echo "ERROR: Kernel config mismatch." >&2
        echo "Expected: $expected" >&2
        grep -E "^CONFIG_${symbol}=" "$OUT/.config" || true
        exit 1
    fi
}

require_config ARCH_PINEAPPLE "CONFIG_ARCH_PINEAPPLE=y"
require_config MODULES "CONFIG_MODULES=y"

for option in \
    MODULE_SIG \
    MODULE_SIG_ALL \
    MODULE_SIG_FORCE \
    MODULE_SIG_PROTECT \
    TRIM_UNUSED_KSYMS
do
    if grep -qx "CONFIG_${option}=y" "$OUT/.config"; then
        echo "ERROR: Required disabled option is enabled: $option" >&2
        exit 1
    fi
done

# ------------------------------------------------------------
# Compile kernel
# ------------------------------------------------------------

echo "Building kernel Image and in-tree modules..."

kmake -j"$JOBS" Image modules

# ------------------------------------------------------------
# WLAN source paths
# ------------------------------------------------------------

MEM="$MODULES/qcom/opensource/datarmnet-ext/mem"
IPA="$MODULES/qcom/opensource/dataipa/drivers/platform/msm"
PLATFORM="$MODULES/qcom/opensource/wlan/platform"
WLAN="$MODULES/qcom/opensource/wlan/qcacld-3.0"

for directory in "$MEM" "$IPA" "$PLATFORM" "$WLAN"; do
    if [[ ! -d "$directory" ]]; then
        echo "ERROR: Required WLAN dependency directory missing: $directory" >&2
        exit 1
    fi
done

# ------------------------------------------------------------
# Compile WLAN dependencies
# ------------------------------------------------------------

echo "Building MEM dependency..."
kmake -j"$JOBS" M="$MEM" modules

echo "Building IPA dependency..."
kmake -j"$JOBS" \
    M="$IPA" \
    KCFLAGS="-I$MEM" \
    KBUILD_EXTRA_SYMBOLS="$MEM/Module.symvers" \
    modules

echo "Building WLAN platform dependency..."
kmake -j"$JOBS" \
    M="$PLATFORM" \
    WLAN_PLATFORM_ROOT="$PLATFORM" \
    modules

# ------------------------------------------------------------
# Compile QCA6750 WLAN
# ------------------------------------------------------------

echo "Building QCA6750 WLAN module..."

kmake -j"$JOBS" \
    M="$WLAN" \
    WLAN_ROOT="$WLAN" \
    WLAN_PROFILE=qca6750 \
    DYNAMIC_SINGLE_CHIP=qca6750 \
    MODNAME=qca_cld3_qca6750 \
    DEVNAME=qca6750 \
    CONFIG_QCA_CLD_WLAN=m \
    CONFIG_QCA_WIFI_ISOC=0 \
    CONFIG_QCA_WIFI_2_0=1 \
    CONFIG_IPA_OUT_OF_TREE=y \
    CLD_IDS=307c8a1 \
    CMN_IDS=307c8a1 \
    KBUILD_EXTRA_SYMBOLS="$MEM/Module.symvers $IPA/Module.symvers $PLATFORM/Module.symvers" \
    modules

KO="$WLAN/qca_cld3_qca6750.ko"

if [[ ! -s "$KO" ]]; then
    echo "ERROR: WLAN module was not generated: $KO" >&2
    exit 1
fi

# ------------------------------------------------------------
# Verify WLAN module
# ------------------------------------------------------------

modinfo "$KO" > "$DIST/wlan-modinfo.txt"

echo "Checking injection parameter..."

if ! grep -q '^parm:.*injection_dp_inflight_limit:' \
    "$DIST/wlan-modinfo.txt"; then

    echo "ERROR: Injection parameter missing from WLAN module." >&2
    exit 1
fi

echo "Checking direct-DP completion symbol..."

if ! llvm-nm-19 "$KO" | grep -q ' T wma_injection_dp_complete$'; then
    echo "ERROR: Direct-DP completion symbol missing." >&2
    exit 1
fi

# Verify WLAN vermagic matches the configured kernel release.
kmake -s --no-print-directory kernelrelease \
    > "$DIST/kernelrelease.txt"

KERNEL_RELEASE="$(cat "$DIST/kernelrelease.txt")"
WLAN_RELEASE="$(modinfo -F vermagic "$KO" | awk '{print $1}')"

echo "Kernel release: $KERNEL_RELEASE"
echo "WLAN release:  $WLAN_RELEASE"

if [[ "$WLAN_RELEASE" != "$KERNEL_RELEASE" ]]; then
    echo "ERROR: WLAN vermagic does not match kernel release." >&2
    exit 1
fi

# ------------------------------------------------------------
# Export kernel artifacts
# ------------------------------------------------------------

echo "Copying kernel build artifacts..."

cp "$OUT/arch/arm64/boot/Image" "$DIST/Image"
cp "$OUT/.config" "$DIST/kernel.config"
cp "$OUT/Module.symvers" "$DIST/Module.symvers"
cp "$OUT/System.map" "$DIST/System.map"

# ------------------------------------------------------------
# Install kernel and external modules into staging
# ------------------------------------------------------------

echo "Installing modules into staging directory..."

rm -rf "$STAGING"
mkdir -p "$STAGING"

kmake \
    INSTALL_MOD_PATH="$STAGING" \
    INSTALL_MOD_STRIP=1 \
    modules_install

for module_dir in "$MEM" "$IPA" "$PLATFORM" "$WLAN"; do
    kmake \
        M="$module_dir" \
        INSTALL_MOD_PATH="$STAGING" \
        INSTALL_MOD_STRIP=1 \
        modules_install
done

# Reject signed modules.
while IFS= read -r -d '' module; do
    signer="$(modinfo -F signer "$module" || true)"

    if [[ -n "$signer" ]]; then
        echo "ERROR: Signed module found: $module" >&2
        exit 1
    fi
done < <(find "$STAGING" -name '*.ko' -print0)

# Remove host-only symlinks.
find "$STAGING/lib/modules" \
    -type l \
    \( -name build -o -name source \) \
    -delete

# Ensure staged WLAN module exists.
if ! find "$STAGING" -name 'qca_cld3_qca6750.ko' -print -quit |
    grep -q .; then

    echo "ERROR: WLAN module missing from staging." >&2
    exit 1
fi

tar -C "$STAGING" -czf "$DIST/modules.tar.gz" lib

# ------------------------------------------------------------
# Build metadata and checksums
# ------------------------------------------------------------

{
    echo "Kernel: $KERNEL_REV"
    echo "Modules: $MODULES_REV"
    echo "Kernel release: $KERNEL_RELEASE"
    echo
    clang-19 --version
    ld.lld-19 --version
    echo
    echo "Patch checksums:"
    sha256sum "$KERNEL_PATCH" "$WLAN_PATCH"
    echo
    echo "Kernel source diff:"
    git -C "$KERNEL" diff --binary | sha256sum
    echo
    echo "WLAN source diff:"
    git -C "$MODULES" diff --binary | sha256sum
} > "$DIST/source-revisions.txt"

# Generate checksums only after all required artifacts exist.
(
    cd "$DIST"

    sha256sum \
        Image \
        modules.tar.gz \
        kernel.config \
        Module.symvers \
        System.map \
        kernelrelease.txt \
        wlan-modinfo.txt \
        source-revisions.txt \
        > SHA256SUMS

    sha256sum --check SHA256SUMS
)

# This marker means compilation and static artifact checks passed.
# It does NOT certify hardware monitor RX or over-air injection.
printf '%s\n' \
    "Compilation and static artifact checks passed." \
    "Device boot, monitor RX, and over-air injection require hardware verification." \
    > "$DIST/BUILD_SUCCESS"

echo
echo "=========================================="
echo "Build and static verification completed."
echo "Kernel release: $KERNEL_RELEASE"
echo "Artifacts: $DIST"
echo "=========================================="
