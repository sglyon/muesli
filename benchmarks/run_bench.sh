#!/usr/bin/env bash
# run_bench.sh — Compare MLX Swift vs mlx-whisper (Python/MLX)
#
# Usage:
#   ./benchmarks/run_bench.sh [WAV_PATH] [--iterations N]
#
# Defaults:
#   WAV_PATH: LJ Speech test clip
#   N: 3

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/native/MuesliNative"
VENV_PYTHON="$ROOT/.venv/bin/python"
DEFAULT_WAV="/tmp/muesli-test-audio/LJ037-0171.wav"

ITERATIONS=3
WAV_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations|-n)
            ITERATIONS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [WAV_PATH] [--iterations N]"
            exit 0 ;;
        -*)
            echo "Unknown flag: $1" >&2; exit 1 ;;
        *)
            WAV_PATH="$1"; shift ;;
    esac
done

if [[ -z "$WAV_PATH" ]]; then
    WAV_PATH="$DEFAULT_WAV"
fi

# Download test audio if not present
if [[ ! -f "$WAV_PATH" ]]; then
    echo "Downloading test audio..."
    mkdir -p "$(dirname "$WAV_PATH")"
    curl -sL "https://keithito.com/LJ-Speech-Dataset/LJ037-0171.wav" -o "$WAV_PATH"
fi

echo "=== Muesli Transcription Benchmark ==="
echo "Audio file : $WAV_PATH"
echo "Iterations : $ITERATIONS (warm runs)"
echo ""

# --- Build Swift benchmark binary ---
echo "--- Building MLXBench (Swift/MLX) ---"
swift build --package-path "$PACKAGE_DIR" -c release --product MLXBench 2>&1
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path 2>/dev/null)"
SWIFT_BIN="$BIN_DIR/MLXBench"
echo ""

# --- Run Swift benchmark ---
echo "--- Running MLX Swift (mlx-swift-audio, fp16) ---"
SWIFT_JSON=$("$SWIFT_BIN" "$WAV_PATH" --iterations "$ITERATIONS" --model small.en --quantization fp16 2>/dev/null)
echo "Done."
echo ""

# --- Run Python benchmark ---
echo "--- Running mlx-whisper (Python/MLX, fp16) ---"
PYTHON_JSON=$("$VENV_PYTHON" "$ROOT/benchmarks/bench_mlx.py" "$WAV_PATH" --iterations "$ITERATIONS" 2>/dev/null)
echo "Done."
echo ""

# --- Comparison table ---
"$VENV_PYTHON" - "$SWIFT_JSON" "$PYTHON_JSON" <<'PYEOF'
import sys, json

swift = json.loads(sys.argv[1])
mlx   = json.loads(sys.argv[2])

def fmt(s):
    return f"{s:.3f}s"

W = 24
print("=" * 64)
print(f"{'Metric':<{W}} {'MLX Swift':>18} {'mlx-whisper (Py)':>18}")
print("-" * 64)

for label, key in [
    ("Model load",   "load_time"),
    ("Cold run",     "cold_time"),
    (f"Warm avg ({swift['iterations']} runs)", "warm_avg"),
    ("Warm best",    "warm_min"),
]:
    sv = swift.get(key, 0.0)
    pv = mlx.get(key, 0.0)
    marker = ""
    if sv < pv:
        pct = ((pv - sv) / pv) * 100
        marker = f"  Swift {pct:.0f}% faster"
    elif pv < sv:
        pct = ((sv - pv) / sv) * 100
        marker = f"  Python {pct:.0f}% faster"
    print(f"  {label:<{W-2}} {fmt(sv):>18} {fmt(pv):>18}{marker}")

print("=" * 64)
print()
print("Transcription output:")
print(f"  MLX Swift  : {swift.get('text','')}")
print(f"  mlx-whisper: {mlx.get('text','')}")
print()
PYEOF
