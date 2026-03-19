#!/usr/bin/env bash

set -e

RUST_BIN="./target/release/bear"
ZIG_BIN="./zig_rewrite/zig-out/bin/bear-zig"
SAMPLES_DIR="./samples"

echo "==> Building Rust (release)..."
cargo build --release 2>&1 | tail -1

echo "==> Building Zig (ReleaseFast)..."
(cd zig_rewrite && zig build -Doptimize=ReleaseFast 2>&1 | tail -1)

echo ""

SKIP_IO_SAMPLES=("read_io.bear" "write_io.bear")

should_skip() {
    local name="$1"
    for s in "${SKIP_IO_SAMPLES[@]}"; do
        [[ "$name" == "$s" ]] && return 0
    done
    return 1
}

if command -v hyperfine &>/dev/null; then
    echo "==> Benchmarking QBE generation with hyperfine (warmup=5, runs=200)..."
    echo ""
    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        should_skip "$name" && continue

        echo "--- $name ---"
        hyperfine \
            --warmup 5 \
            --runs 200 \
            --command-name "rust  bear qbe" "$RUST_BIN qbe $f" \
            --command-name "zig bear-zig qbe" "$ZIG_BIN qbe $f"
        echo ""
    done

    echo "==> Combined (all samples, 200 runs each)..."
    rust_cmds=()
    zig_cmds=()
    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        should_skip "$name" && continue
        rust_cmds+=("$RUST_BIN qbe $f")
        zig_cmds+=("$ZIG_BIN qbe $f")
    done

    hf_args=(--warmup 5 --runs 200)
    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        should_skip "$name" && continue
        stem="${name%.bear}"
        hf_args+=(--command-name "rust/$stem"  "$RUST_BIN qbe $f")
        hf_args+=(--command-name "zig/$stem"   "$ZIG_BIN  qbe $f")
    done
    hyperfine "${hf_args[@]}"

else
    echo "==> hyperfine not found — falling back to manual timing (200 runs each)..."
    echo "    Install hyperfine for richer output: brew install hyperfine"
    echo ""

    RUNS=200

    avg_ns() {
        local bin="$1"; shift
        local args=("$@")
        local total=0 start end
        for _ in $(seq 1 "$RUNS"); do
            start=$(date +%s%N)
            "$bin" "${args[@]}" > /dev/null 2>&1
            end=$(date +%s%N)
            total=$((total + end - start))
        done
        echo $((total / RUNS))
    }

    printf "%-22s %10s %10s %10s %s\n" "sample" "rust(µs)" "zig(µs)" "ratio" "winner"
    printf "%-22s %10s %10s %10s %s\n" "------" "--------" "-------" "-----" "------"

    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        should_skip "$name" && continue

        rust_ns=$(avg_ns "$RUST_BIN" qbe "$f")
        zig_ns=$(avg_ns  "$ZIG_BIN"  qbe "$f")
        rust_us=$(( rust_ns / 1000 ))
        zig_us=$(( zig_ns  / 1000 ))

        if [ "$zig_ns" -lt "$rust_ns" ] && [ "$zig_ns" -gt 0 ]; then
            ratio=$(awk "BEGIN{printf \"%.2f\", $rust_ns/$zig_ns}")
            winner="zig  (${ratio}x)"
        elif [ "$rust_ns" -gt 0 ]; then
            ratio=$(awk "BEGIN{printf \"%.2f\", $zig_ns/$rust_ns}")
            winner="rust (${ratio}x)"
        else
            winner="tie"
        fi

        printf "%-22s %10d %10d %10s %s\n" \
            "${name%.bear}" "$rust_us" "$zig_us" "" "$winner"
    done
    echo ""
fi
