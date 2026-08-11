#!/usr/bin/env bash
#
# smoke-test.sh — run a freshly built ds4 bundle on real gfx1151 hardware.
#
# This is the gate that decides whether a daily build gets published. GitHub's
# hosted runners have no AMD GPU, so the build job can only prove the bundle is
# self-contained; it cannot prove the binary runs. Everything that has actually
# broken here (a missing liborigami, a dangling SONAME) was invisible until
# something executed the binary.
#
#   MODEL=/path/to.gguf ./scripts/smoke-test.sh <unpacked-bundle-dir>
set -euo pipefail

BUNDLE="${1:?usage: smoke-test.sh <unpacked-bundle-dir>}"
# Optional: the inference stage needs ~81 GiB resident, so it only runs where a
# model is available and the box is big enough. Link-level checks always run.
MODEL="${MODEL:-}"
MIN_TPS="${MIN_TPS:-8}"          # conservative: measured ~16-17 t/s on gfx1151
EXPECT_ARCH="${EXPECT_ARCH:-gfx1151}"
TOKENS="${TOKENS:-64}"
CTX="${CTX:-4096}"

say() { printf '==> %s\n' "$*"; }
fail() { printf '!!! %s\n' "$*" >&2; exit 1; }

[ -d "$BUNDLE" ] || fail "bundle dir not found: $BUNDLE"

# ds4 refuses to start while another instance is running, so one leftover
# process — a cancelled job, an interrupted run, someone's session — blocks
# every future build on a shared runner. Report that distinctly instead of
# letting it look like the build is broken.
stale=$(pgrep -x ds4 || true; pgrep -x ds4-server || true)
if [ -n "$stale" ]; then
    echo "another ds4 instance is already running:" >&2
    ps -o pid,etime,args -p $(echo "$stale" | tr '\n' ',' | sed 's/,$//') 2>/dev/null >&2 || true
    if [ "${ALLOW_KILL_STALE:-0}" = "1" ]; then
        say "ALLOW_KILL_STALE=1, terminating stale instances"
        # shellcheck disable=SC2086
        kill $stale 2>/dev/null || true
        sleep 10
        pgrep -x ds4 >/dev/null || pgrep -x ds4-server >/dev/null && sleep 10 || true
    else
        fail "runner is dirty, not a build failure — clear the stale ds4 process, or set ALLOW_KILL_STALE=1 on a dedicated runner"
    fi
fi

cd "$BUNDLE"
export LD_LIBRARY_PATH="$PWD"

# 1. The binary must resolve every library from inside the bundle. A dependency
# satisfied by a system ROCm install would pass here and fail on a clean host.
say "checking the bundle resolves its own dependencies"
missing=$(ldd ./ds4-server 2>/dev/null | awk '/not found/{print $1}')
[ -z "$missing" ] || fail "unresolved libraries: $missing"
outside=$(ldd ./ds4-server 2>/dev/null \
    | awk -v b="$PWD" '$3 ~ /(hip|rocblas|amd_comgr|hsa|origami|rocm)/ && $3 !~ b {print $1" -> "$3}')
if [ -n "$outside" ]; then
    printf '%s\n' "$outside" >&2
    fail "ROCm libraries resolved outside the bundle"
fi

# 2. The binaries must load and run. Both bundling bugs this pipeline has hit
# (a missing liborigami, a dangling SONAME) failed here — at dynamic-link time,
# before main — so this catches them without needing a model. LD_BIND_NOW forces
# every symbol to resolve up front rather than lazily.
say "executing the binaries with full symbol resolution"
for b in ds4 ds4-server ds4-bench ds4-eval ds4-agent; do
    [ -x "./$b" ] || fail "missing binary: $b"
    LD_BIND_NOW=1 timeout 120 "./$b" --help >/dev/null 2>&1 || fail "$b failed to load and run"
done

# 3. The host has to be the architecture this bundle was compiled for, or the
# inference stage below is meaningless.
# Matched with a case rather than `| grep -q`: under `set -o pipefail`, grep -q
# exits at the first match, the producer takes SIGPIPE, and a successful match
# reads as a failed pipeline.
if command -v rocminfo >/dev/null 2>&1; then
    arch_out=$(rocminfo 2>/dev/null || true)
    case "$arch_out" in
        *"$EXPECT_ARCH"*) say "host reports $EXPECT_ARCH" ;;
        *) fail "host does not report $EXPECT_ARCH" ;;
    esac
fi

# 4. Inference, where the hardware can hold the model. A 64 GiB box cannot make
# an 80.76 GiB model resident at any gttsize, so this stage is skipped there
# rather than failing a build that is fine.
if [ -z "$MODEL" ]; then
    say "SKIPPED inference: no MODEL set"
    say "link-level checks passed"
    exit 0
fi
if [ ! -f "$MODEL" ]; then
    fail "MODEL is set but not found: $MODEL"
fi
# Capacity is the largest single GPU memory pool, not system RAM and not the
# sum of the pools. ds4 allocates its model arena from device memory and does
# not spill into GTT: on a box with a 64 GiB BIOS VRAM carve-out and a 31 GiB
# GTT aperture it OOMs at the 64 GiB boundary despite 95 GiB "available".
# Strix Halo is usable either way round — minimal BIOS VRAM with GTT raised to
# most of RAM, or a large carve-out — but one pool has to be big enough alone.
pool_gib=0
for f in /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total; do
    [ -e "$f" ] || continue
    this_gib=$(( $(cat "$f") / 1024 / 1024 / 1024 ))
    [ "$this_gib" -gt "$pool_gib" ] && pool_gib=$this_gib
done
if [ "$pool_gib" -lt "${MIN_GPU_GIB:-90}" ]; then
    say "SKIPPED inference: largest GPU memory pool is ${pool_gib} GiB, need >= ${MIN_GPU_GIB:-90}"
    say "  (reduce the BIOS VRAM carve-out and raise the GTT aperture to enable it)"
    say "link-level checks passed"
    exit 0
fi
say "largest GPU memory pool: ${pool_gib} GiB"

say "running inference on $EXPECT_ARCH"
out=$(timeout 1800 ./ds4 -m "$MODEL" \
        -p "In one sentence, what is the capital of France?" \
        -n "$TOKENS" --temp 0 -c "$CTX" 2>&1) || fail "ds4 exited non-zero:\n$out"

printf '%s\n' "$out" | tail -5

case "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" in
    *paris*) ;;
    *) fail "model did not produce the expected answer" ;;
esac

# 3. Guard against a build that runs but is badly slower — a broken kernel
# selection or a CPU fallback would still answer correctly, just slowly.
tps=$(printf '%s' "$out" | grep -oE "generation: [0-9.]+ t/s" | tail -1 | grep -oE "[0-9.]+" || true)
[ -n "$tps" ] || fail "no generation throughput reported"
say "generation: ${tps} t/s (floor ${MIN_TPS})"
awk -v t="$tps" -v m="$MIN_TPS" 'BEGIN { exit !(t >= m) }' \
    || fail "generation ${tps} t/s is below the ${MIN_TPS} t/s floor"

say "smoke test passed"
