#!/usr/bin/env bash
# Benchmark: Rust bear vs Zig bear-zig
# Requires: hyperfine (brew install hyperfine) or falls back to manual timing

set -e

RUST_BIN="./target/release/bear"
ZIG_BIN="./zig_rewrite/zig-out/bin/bear-zig"
SAMPLES_DIR="./samples"

# Build both in release mode
echo "==> Building Rust (release)..."
cargo build --release 2>&1 | tail -1

echo "==> Building Zig (ReleaseFast)..."
(cd zig_rewrite && zig build -Doptimize=ReleaseFast 2>&1 | tail -1)

echo ""
echo "==> Verifying outputs match..."
for f in "$SAMPLES_DIR"/*.bear; do
    name=$(basename "$f")
    # skip IO samples that need files on disk
    if [[ "$name" == "read_io.bear" || "$name" == "write_io.bear" ]]; then
        echo "  skipping $name (file I/O)"
        continue
    fi
    rust_out=$("$RUST_BIN" "$f" 2>/dev/null || true)
    zig_out=$("$ZIG_BIN"  "$f" 2>/dev/null || true)
    if [ "$rust_out" = "$zig_out" ]; then
        echo "  $name: outputs match ✓"
    else
        echo "  $name: MISMATCH ✗"
        echo "    rust: $rust_out"
        echo "    zig:  $zig_out"
    fi
done

echo ""

# Use hyperfine if available, otherwise manual loop
if command -v hyperfine &>/dev/null; then
    echo "==> Benchmarking with hyperfine (warmup=3, runs=50)..."
    echo ""
    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        if [[ "$name" == "read_io.bear" || "$name" == "write_io.bear" ]]; then
            continue
        fi
        echo "--- $name ---"
        hyperfine \
            --warmup 3 \
            --runs 50 \
            --command-name "rust" "$RUST_BIN $f" \
            --command-name "zig"  "$ZIG_BIN  $f" \
            2>/dev/null || true
        echo ""
    done
else
    echo "==> hyperfine not found, using manual timing (100 runs each)..."
    echo ""
    RUNS=100

    time_cmd() {
        local bin="$1" file="$2"
        local start end elapsed total=0
        for _ in $(seq 1 $RUNS); do
            start=$(date +%s%N)
            "$bin" "$file" > /dev/null 2>&1 || true
            end=$(date +%s%N)
            total=$((total + end - start))
        done
        echo $((total / RUNS))
    }

    for f in "$SAMPLES_DIR"/*.bear; do
        name=$(basename "$f")
        if [[ "$name" == "read_io.bear" || "$name" == "write_io.bear" ]]; then
            continue
        fi
        echo "--- $name ($RUNS runs) ---"
        rust_ns=$(time_cmd "$RUST_BIN" "$f")
        zig_ns=$(time_cmd  "$ZIG_BIN"  "$f")
        rust_us=$((rust_ns / 1000))
        zig_us=$((zig_ns  / 1000))
        echo "  rust:    ${rust_us} µs avg"
        echo "  zig:     ${zig_us} µs avg"
        if [ "$zig_ns" -lt "$rust_ns" ]; then
            ratio=$(echo "scale=2; $rust_ns / $zig_ns" | bc)
            echo "  winner:  zig (${ratio}x faster)"
        else
            ratio=$(echo "scale=2; $zig_ns / $rust_ns" | bc)
            echo "  winner:  rust (${ratio}x faster)"
        fi
        echo ""
    done
fi

echo "end"
