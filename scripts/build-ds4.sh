#!/usr/bin/env bash
#
# build-ds4.sh — build ds4 for one ROCm GPU target and stage a redistributable
# bundle (binaries + the ROCm runtime they need).
#
# Used by .github/workflows/build-ds4-rocm.yml, and runnable locally to
# reproduce a release build.
#
#   ROCM_DIR=/opt/rocm GFX=gfx1151 DS4_REF=main ./scripts/build-ds4.sh out/
#
# Requires: git, make, and a ROCm toolchain (hipcc) in $ROCM_DIR.
set -euo pipefail

OUT_DIR="${1:?usage: build-ds4.sh <output-dir>}"
ROCM_DIR="${ROCM_DIR:-/opt/rocm}"
GFX="${GFX:-gfx1151}"
DS4_REF="${DS4_REF:-main}"
DS4_REPO="${DS4_REPO:-https://github.com/antirez/ds4.git}"
ROCWMMA_TAG="${ROCWMMA_TAG:-rocm-7.1.0}"
SRC_DIR="${SRC_DIR:-$PWD/ds4-src}"

say() { printf '==> %s\n' "$*"; }

HIPCC="$ROCM_DIR/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc || true)"
[ -n "$HIPCC" ] && [ -x "$HIPCC" ] || { echo "!!! no hipcc under $ROCM_DIR or on PATH" >&2; exit 1; }

say "Fetching ds4 ($DS4_REF)"
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone "$DS4_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --all --tags
git -C "$SRC_DIR" checkout --detach "$DS4_REF"
DS4_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
say "ds4 commit $DS4_SHA"

# ds4's Strix Halo backend includes <rocwmma/internal/...>. librocwmma-dev ships
# the top-level headers but not internal/, and no distro package provides them,
# so pull a complete matching tree. This is the single most annoying part of
# building ds4 by hand, and the main thing these binaries save users.
say "Staging rocWMMA headers ($ROCWMMA_TAG)"
ROCWMMA_SRC="${ROCWMMA_SRC:-$PWD/rocWMMA-$ROCWMMA_TAG}"
if [ ! -d "$ROCWMMA_SRC" ]; then
    git clone --depth 1 --branch "$ROCWMMA_TAG" https://github.com/ROCm/rocWMMA.git "$ROCWMMA_SRC"
fi
INC_DIR="$PWD/stage-include"
mkdir -p "$INC_DIR"
cp -a "$ROCWMMA_SRC/library/include/rocwmma" "$INC_DIR/"
[ -d "$INC_DIR/rocwmma/internal" ] || { echo "!!! rocwmma/internal missing" >&2; exit 1; }

say "Building ds4 for $GFX"
make -C "$SRC_DIR" strix-halo -j"$(nproc)" \
    HIPCC="$HIPCC" \
    ROCM_ARCH="$GFX" \
    CFLAGS="-O3 -ffast-math -g -march=x86-64-v3 -Wall -Wextra -std=c99 -D_GNU_SOURCE -fno-finite-math-only -I$INC_DIR" \
    ROCM_CFLAGS="-O3 -ffast-math -g -fno-finite-math-only -pthread -D__HIP_PLATFORM_AMD__ -Wno-unused-command-line-argument --offload-arch=$GFX -I$INC_DIR"

BINS="ds4 ds4-server ds4-bench ds4-eval ds4-agent"
mkdir -p "$OUT_DIR"
for b in $BINS; do
    [ -x "$SRC_DIR/$b" ] || { echo "!!! missing built binary $b" >&2; exit 1; }
    cp "$SRC_DIR/$b" "$OUT_DIR/"
done

# Bundle the ROCm runtime so the target host needs no system ROCm. Copy what the
# binaries actually link plus the hipBLASLt/rocBLAS tuning data they load at
# runtime (those directories are the bulk of the payload).
say "Bundling ROCm runtime"
# -L matters: $ROCM_DIR/lib is a symlink on distro ROCm installs, and find will
# not descend into a symlinked directory without it (silently bundling nothing).
LIB_DIR="$(readlink -f "$ROCM_DIR/lib")"
copy_lib() {
    local pat=$1
    find -L "$LIB_DIR" -maxdepth 1 -name "$pat" -exec cp -P {} "$OUT_DIR/" \; 2>/dev/null || true
}
for pat in 'libamdhip64.so*' 'libhipblas.so*' 'libhipblaslt.so*' 'librocblas.so*' \
           'libamd_comgr.so*' 'libhsa-runtime64.so*' 'librocprofiler-register.so*' \
           'libLLVM*.so*' 'libroctx64.so*' 'libhsakmt.so*'; do
    copy_lib "$pat"
done
for d in hipblaslt rocblas; do
    [ -d "$LIB_DIR/$d" ] && cp -a "$LIB_DIR/$d" "$OUT_DIR/" || true
done

# hipBLASLt and rocBLAS ship precompiled kernels for every supported GPU. In a
# single-target bundle that is ~1.1 GiB of tuning data for hardware this build
# cannot run on. Keep only this target's kernels plus the arch-neutral files.
say "Pruning tuning data to $GFX"
before=$(du -sm "$OUT_DIR" | cut -f1)
for d in hipblaslt rocblas; do
    [ -d "$OUT_DIR/$d" ] || continue
    find "$OUT_DIR/$d" -type f -name '*gfx*' ! -name "*${GFX}*" -delete
done
after=$(du -sm "$OUT_DIR" | cut -f1)
say "tuning data pruned: ${before} MiB -> ${after} MiB"

# Anything still resolving outside the bundle would break on a host without
# ROCm, so report it rather than shipping a bundle that only works here.
say "Checking for unbundled ROCm dependencies"
missing=0
for b in $BINS; do
    while read -r lib; do
        case "$lib" in
            libamdhip64*|libhipblas*|libhipblaslt*|librocblas*|libamd_comgr*|libhsa-runtime64*|libhsakmt*)
                [ -e "$OUT_DIR/$lib" ] || { echo "  MISSING: $lib (needed by $b)"; missing=1; } ;;
        esac
    done < <(objdump -p "$OUT_DIR/$b" 2>/dev/null | awk '/NEEDED/{print $2}')
done
[ "$missing" -eq 0 ] && say "all ROCm deps bundled" || echo "!!! bundle incomplete (see above)"

echo "$DS4_SHA" > "$OUT_DIR/ds4-commit.txt"
say "Staged $(du -sh "$OUT_DIR" | cut -f1) in $OUT_DIR"
