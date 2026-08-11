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
MODEL="${MODEL:?set MODEL to a DeepSeek-V4-Flash GGUF}"
MIN_TPS="${MIN_TPS:-8}"          # conservative: measured ~16-17 t/s on gfx1151
TOKENS="${TOKENS:-64}"
CTX="${CTX:-4096}"

say() { printf '==> %s\n' "$*"; }
fail() { printf '!!! %s\n' "$*" >&2; exit 1; }

[ -d "$BUNDLE" ] || fail "bundle dir not found: $BUNDLE"
[ -f "$MODEL" ]  || fail "model not found: $MODEL"

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

# 2. It must actually run on the GPU and produce the right answer. Greedy, so
# the expected output is deterministic.
say "running inference on gfx1151"
out=$(timeout 1800 ./ds4 -m "$MODEL" \
        -p "In one sentence, what is the capital of France?" \
        -n "$TOKENS" --temp 0 -c "$CTX" 2>&1) || fail "ds4 exited non-zero:\n$out"

printf '%s\n' "$out" | tail -5

printf '%s' "$out" | grep -qi "paris" \
    || fail "model did not produce the expected answer"

# 3. Guard against a build that runs but is badly slower — a broken kernel
# selection or a CPU fallback would still answer correctly, just slowly.
tps=$(printf '%s' "$out" | grep -oE "generation: [0-9.]+ t/s" | tail -1 | grep -oE "[0-9.]+" || true)
[ -n "$tps" ] || fail "no generation throughput reported"
say "generation: ${tps} t/s (floor ${MIN_TPS})"
awk -v t="$tps" -v m="$MIN_TPS" 'BEGIN { exit !(t >= m) }' \
    || fail "generation ${tps} t/s is below the ${MIN_TPS} t/s floor"

say "smoke test passed"
