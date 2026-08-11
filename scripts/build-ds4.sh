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
say "Bundling ROCm runtime (transitive closure)"
# -L matters: $ROCM_DIR/lib is a symlink on distro ROCm installs, and find will
# not descend into a symlinked directory without it (silently bundling nothing).
LIB_DIR="$(readlink -f "$ROCM_DIR/lib")"

# Walk NEEDED entries transitively rather than copying a hardcoded list of
# library names. ROCm distributions differ in what they pull in — TheRock's
# hipBLASLt needs liborigami, distro ROCm does not — and a fixed list silently
# produces a bundle that only runs on the machine that built it.
declare -A SEEN=()
queue=()
for b in $BINS; do queue+=("$OUT_DIR/$b"); done
while [ ${#queue[@]} -gt 0 ]; do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    [ -f "$cur" ] || continue
    while read -r need; do
        [ -n "$need" ] || continue
        [ -n "${SEEN[$need]:-}" ] && continue
        SEEN[$need]=1
        src="$LIB_DIR/$need"
        [ -e "$src" ] || continue          # not ROCm-provided; base system lib
        cp -a "$src" "$OUT_DIR/" 2>/dev/null || true
        real="$(readlink -f "$src")"
        if [ "$real" != "$src" ] && [ -e "$real" ]; then
            cp -a "$real" "$OUT_DIR/" 2>/dev/null || true
        fi
        queue+=("$real")
    done < <(objdump -p "$cur" 2>/dev/null | awk '/NEEDED/{print $2}')
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

# Verify against a base-system allowlist instead of a ROCm-name allowlist: any
# NEEDED entry that is neither in the bundle nor part of a stock glibc/libstdc++
# install would break on a host without ROCm. An earlier version of this check
# only knew ROCm library names and happily passed a bundle missing liborigami,
# which then failed at exec time.
say "Verifying bundle is self-contained"
is_base_lib() {
    case "$1" in
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*|\
        libstdc++.so.*|libgcc_s.so.*|libgomp.so.*|libnuma.so.*|libdrm*.so.*|\
        libelf.so.*|libz.so.*|libzstd.so.*|libtinfo.so.*|libatomic.so.*) return 0 ;;
        *) return 1 ;;
    esac
}
missing=0
for f in "$OUT_DIR"/*; do
    [ -f "$f" ] || continue
    file "$f" 2>/dev/null | grep -q ELF || continue
    while read -r lib; do
        [ -n "$lib" ] || continue
        [ -e "$OUT_DIR/$lib" ] && continue
        is_base_lib "$lib" && continue
        echo "  MISSING: $lib (needed by $(basename "$f"))"
        missing=1
    done < <(objdump -p "$f" 2>/dev/null | awk '/NEEDED/{print $2}')
done
if [ "$missing" -eq 0 ]; then
    say "bundle is self-contained"
else
    echo "!!! bundle incomplete — it would fail on a host without ROCm" >&2
    exit 1
fi

echo "$DS4_SHA" > "$OUT_DIR/ds4-commit.txt"
say "Staged $(du -sh "$OUT_DIR" | cut -f1) in $OUT_DIR"
