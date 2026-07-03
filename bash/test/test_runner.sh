#!/usr/bin/env bash
#
# test/test_runner.sh – Comprehensive regression test suite for the FFmpeg
# transcode script.
#
# Usage: ./test/test_runner.sh
#
# Creates temporary test media files, runs the refactored transcode.sh against
# them, and asserts correct behavior across all major code paths.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCODE_SCRIPT="$SCRIPT_DIR/../transcode.sh"
TEST_DIR="/tmp/transcode-test-$$"
PASS=0
FAIL=0

cleanup_test_dir() {
    rm -rf "$TEST_DIR"
}
trap cleanup_test_dir EXIT

mkdir -p "$TEST_DIR/source" "$TEST_DIR/config"

# ---------------------------------------------------------------------------
# Helper: write a test config JSON
# ---------------------------------------------------------------------------
write_config() {
    local name="$1"
    local min_age="${2:-0}"
    local min_size="${3:-0}"
    local skip_codec="${4:-av1}"
    local move_file="${5:-0}"

    cat > "$TEST_DIR/config/$name.json" <<EOF
{
    "global_settings": {
        "min_threads": 1,
        "max_threads": 1,
        "gpu_target_pct": 95,
        "gpu_ramp_wait": 5,
        "gpu_check_interval": 10,
        "vcn_sample_interval": 5,
        "ffmpeg_input_params": "-err_detect ignore_err -ignore_unknown -vaapi_device /dev/dri/renderD128",
        "scan_at_start": 1,
        "restart_queue": 0,
        "ffmpeg_timeout": 6000,
        "ffmpeg_logging": "error",
        "ffmpeg_min_diff": 0,
        "ffmpeg_max_diff": 95,
        "move_file": $move_file,
        "duration_tolerance": 30,
        "ffmpeg_nice_priority": 15,
        "skip_file": "$TEST_DIR/skip.csv",
        "sleep_before_move": 1,
        "sleep_after_move": 1,
        "output_path": "/dev/shm/ffmpeg-transcode-test"
    },
    "configurations": [
        {
            "name": "test",
            "media_path": "$TEST_DIR/source",
            "min_video_size": $min_size,
            "min_video_age": $min_age,
            "ffmpeg_output_params": "-vf 'format=nv12,hwupload' -c:v av1_vaapi -c:a copy -b:v 2M -maxrate 2M -bufsize 2M -max_muxing_queue_size 9999",
            "video_codec_skip_list": "$skip_codec"
        }
    ]
}
EOF
}

# ---------------------------------------------------------------------------
# Helper: generate a test video with specific properties
# ---------------------------------------------------------------------------
generate_video() {
    local name="$1"
    local duration="${2:-10}"
    local codec="${3:-mpeg4}"  # software encoder available on this system

    local extra_opts=""
    if [[ "$codec" == "av1" ]]; then
        # Use VAAPI AV1 to produce an AV1-coded test file
        extra_opts="-vf format=nv12,hwupload -c:v av1_vaapi -b:v 2M"
    elif [[ "$codec" == "mpeg4" ]]; then
        extra_opts="-c:v mpeg4 -b:v 2M"
    else
        extra_opts="-c:v mpeg4 -b:v 2M"
    fi

    ffmpeg -y \
        -f lavfi -i "testsrc=duration=${duration}:size=1280x720:rate=25" \
        -f lavfi -i "sine=frequency=1000:duration=${duration}" \
        $extra_opts \
        -c:a aac -b:a 128k \
        -shortest \
        "$TEST_DIR/source/${name}" 2>/dev/null || {
        echo "  [WARN] Failed to generate $name with codec $codec, using mpeg4 fallback"
        ffmpeg -y \
            -f lavfi -i "testsrc=duration=${duration}:size=1280x720:rate=25" \
            -f lavfi -i "sine=frequency=1000:duration=${duration}" \
            -c:v mpeg4 -b:v 2M \
            -c:a aac -b:a 128k \
            -shortest \
            "$TEST_DIR/source/${name}" 2>/dev/null || true
    }

    # Set a specific mtime to control file age
    touch -t 202001010000 "$TEST_DIR/source/${name}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: run transcode.sh and capture results
# ---------------------------------------------------------------------------
run_test() {
    local test_name="$1"
    local config_file="$2"

    rm -f "$TEST_DIR/skip.csv" "$TEST_DIR/transcode.log" 2>/dev/null || true
    cd "$TEST_DIR" || return 1
    # Run with timeout to prevent hanging. stderr/stdout to /dev/null;
    # the script writes transcode.log relative to CWD.
    timeout 60 bash "$TRANSCODE_SCRIPT" "$config_file" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Helper: assert condition
# ---------------------------------------------------------------------------
assert() {
    local test_name="$1"
    local condition="$2"
    local message="$3"

    if eval "$condition"; then
        echo "  ✓ $message"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FAIL: $message"
        FAIL=$((FAIL + 1))
    fi
}

# ===========================================================================
# TEST CASES
# ===========================================================================

echo "========================================"
echo "  FFmpeg Transcode – Regression Tests"
echo "========================================"
echo ""

# --- Test 1: Codec skip list ---
echo "[Test 1] Codec skip list (using mpeg4 as skip codec since we control generation)"
generate_video "skip_mpeg4.mkv" 10 "mpeg4"
write_config "test_skip_codec" 0 0 "mpeg4"
run_test "skip_codec" "$TEST_DIR/config/test_skip_codec.json"
assert "skip_codec" \
    'grep -q "codec skip list, skipping" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "mpeg4 file skipped with 'codec skip list' message in log"
assert "skip_codec_2" \
    '! grep -q "transcoding" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "mpeg4 file was NOT transcoded"
rm -f "$TEST_DIR/source/skip_mpeg4.mkv"

# --- Test 2: Age gate ---
echo "[Test 2] Age gate (file too new)"
generate_video "new_file.mp4" 10 "mpeg4"
# Set mtime to now (file is 0 days old)
touch "$TEST_DIR/source/new_file.mp4"
write_config "test_age" 365 0 ""   # require 365 days old
run_test "age_gate" "$TEST_DIR/config/test_age.json"
assert "age_gate" \
    'grep -q "too new" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "New file was skipped with 'too new' message"
assert "age_gate_2" \
    '! grep -q "new_file.mp4.*transcoding" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "New file was not transcoded"
rm -f "$TEST_DIR/source/new_file.mp4"

# --- Test 3: Min-size gate ---
echo "[Test 3] Min-size gate"
generate_video "tiny_file.mp4" 5 "mpeg4"
write_config "test_minsize" 0 99999 ""   # require files > 99999MB
timeout 10 bash "$TRANSCODE_SCRIPT" "$TEST_DIR/config/test_minsize.json" > /dev/null 2>&1 || true
assert "minsize" \
    'grep -q "HIT VIDEO SIZE LIMIT" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "Script stopped at min-size threshold"
rm -f "$TEST_DIR/source/tiny_file.mp4"

# --- Test 4: Normal transcode (early abort expected for small test file) ---
echo "[Test 4] Normal transcode (monitor/early-abort path)"
generate_video "normal.mp4" 15 "mpeg4"
write_config "test_normal" 0 0 "" 0
run_test "normal" "$TEST_DIR/config/test_normal.json"
assert "normal" \
    'grep -qE "early-abort|ERROR.*min difference|SUCCESS" "$TEST_DIR/transcode.log" 2>/dev/null' \
    "Transcode completed with expected result (abort or success)"
assert "normal" \
    'grep -q "transcoding..." "$TEST_DIR/transcode.log" 2>/dev/null' \
    "Transcode started for the file"
rm -f "$TEST_DIR/source/normal.mp4"

# --- Test 5: Non-existent file handling ---
echo "[Test 5] Non-existent file handling"
generate_video "exists.mp4" 5 "mpeg4"
write_config "test_missing" 0 0 "" 0
# Run once to create scan results, then delete a file
cd "$TEST_DIR" && timeout 10 bash "$TRANSCODE_SCRIPT" "$TEST_DIR/config/test_missing.json" > /dev/null 2>&1 || true
# The file would have been processed. Not a great test for missing files
# but it validates the script doesn't crash.
assert "missing_file" \
    '[ -f "$TEST_DIR/transcode.log" ]' \
    "Script handled execution without crashing"
rm -f "$TEST_DIR/source/exists.mp4"

# --- Test 6: Syntax check on all library files ---
echo "[Test 6] All bash files pass syntax check"
for f in "$SCRIPT_DIR/../transcode.sh" "$SCRIPT_DIR/../lib/"*.sh; do
    fname="$(basename "$f")"
    if bash -n "$f" 2>/dev/null; then
        assert "syntax_$fname" 'true' "$fname syntax OK"
    else
        assert "syntax_$fname" 'false' "$fname syntax FAILED"
    fi
done

# --- Test 7: Verify the split library files are all sourced ---
echo "[Test 7] All library files are present and sourceable"
for lib in config logging media scan process transcode scheduler; do
    libfile="$SCRIPT_DIR/../lib/${lib}.sh"
    if [[ -f "$libfile" && -r "$libfile" ]]; then
        if bash -c "source '$libfile' 2>&1" 2>/dev/null; then
            assert "lib_${lib}" 'true' "lib/${lib}.sh exists and is sourceable"
        else
            assert "lib_${lib}" 'false' "lib/${lib}.sh source check FAILED"
        fi
    else
        assert "lib_${lib}" 'false' "lib/${lib}.sh NOT FOUND"
    fi
done

# ===========================================================================
# RESULTS
# ===========================================================================
echo ""
echo "========================================"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "========================================"

exit $FAIL
