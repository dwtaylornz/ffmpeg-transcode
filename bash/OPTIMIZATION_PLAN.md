# transcode.sh Optimization Plan

## Executive Summary

The script has grown from ~21 KB to **50.6 KB** across 20+ iterations, accumulating duplicate code paths, dense logic blocks, and inconsistent patterns. This plan outlines a structured cleanup that preserves all existing functionality while improving readability, maintainability, and correctness. A regression test pass is required before and after each refactor phase.

---

## Phase 0 — Baseline & Regression Test (DO NOT SKIP)

**Goal:** Establish a working benchmark so we can prove nothing breaks during refactoring.

### 0a. Capture current state
- Record script size, line count, function count
- Run the smoke test and capture full output → `baseline_regression.log`
- Note: The regression log shows `run_media_scan: command not found` — this is a **known bug** (background subshell can't see functions defined in parent). Fixing this is itself a correctness fix.

### 0b. Define "pass" criteria
A refactor passes if the smoke test produces identical behavior for:
1. Media scan finds all 6 test videos
2. Each video transcodes successfully (or correctly skips)
3. Skip file is written with correct reasons
4. Log output contains expected SUCCESS/ERROR/WARN markers
5. Exit code is 0

### 0c. Benchmark metrics to capture
| Metric | How |
|--------|-----|
| Script size (bytes, lines) | `wc -c`, `wc -l` |
| Function count | `grep -c '^[a-z_]*()' transcode.sh` |
| Smoke test wall-clock time | From regression log |
| Scan time per config | From log timestamps |
| Transcode time per video | From log timestamps |

---

## Phase 1 — Fix the Regression Bug (Correctness)

**Issue:** `run_media_scan` is called inside `( ... ) &` background subshell. Bash functions are not inherited by subshells created with `(...)`. The function must be exported or the scan logic restructured.

**Fix options:**
- **Option A:** Use `export -f run_media_scan merge_scan_results` then call in subshell (cleanest)
- **Option B:** Inline the scan logic into the background block (duplicates code)
- **Option C:** Move scan to foreground always, accept slower startup

**Recommendation:** Option A — minimal change, fixes the bug.

---

## Phase 2 — Eliminate Code Duplication

### 2a. Extract shared metadata extraction
`run_job_transcode()` and `post_transcode_checks()` both run identical ffprobe + jq to extract video/audio codec, channels, width, duration, audio stream count.

**Action:** Create a single function:
```bash
extract_media_metadata() {
    local json="$1"
    # Returns the same space-separated fields as current _meta extraction
}
```
Then both callers just do `read -r video_codec audio_codec ... <<< "$(extract_media_metadata "$json")"`.

**Estimated savings:** ~40 lines of duplicated jq + read logic.

### 2b. Extract shared cleanup pattern
`cleanup_job_folder "$output_path"` is called in 8+ places after error conditions. Create a helper:
```bash
fail_and_cleanup() {
    local job="$1" video_name="$2" reason="$3" output_path="$4"
    write_skip_error "$video_name" "$reason"
    cleanup_job_folder "$output_path"
}
```

**Estimated savings:** ~16 lines, plus clearer intent.

### 2c. Consolidate skip-file writing
`write_skip()` and `write_skip_error()` are nearly identical (one just calls the other). Merge into a single function with an optional reason parameter.

---

## Phase 3 — Simplify Complex Logic Blocks

### 3a. Extract GPU scaling logic from main loop
The inner `while true; do ... done` loop contains ~80 lines of mixed concerns:
- Slot availability checking
- Timeout detection
- OOO (out-of-order) dispatch for shm-constrained videos
- VCN sampling and headroom evaluation
- Scale-up/scale-down decisions

**Action:** Split into focused functions:
```bash
check_slot_available() { ... }      # Is this thread slot free?
dispatch_video_to_slot() { ... }    # Launch transcode in a slot
evaluate_gpu_headroom() { ... }     # VCN-based scale decision
try_ooo_dispatch() { ... }          # Find smaller video that fits shm
```

**Benefit:** Each function becomes 15-20 lines instead of one 80-line block. Easier to test each piece independently.

### 3b. Simplify the format glob list
The `-iname '*.ext'` chain in `run_media_scan()` is ~40 extensions hardcoded into a single find command.

**Action:** Define an array at the top:
```bash
VIDEO_EXTENSIONS=(*.3g2 *.3gp *.asf *.avi ... *.y4m)
```
Then use `${VIDEO_EXTENSIONS[@]}` in the find command via `-o -iname`.

**Benefit:** Adding a new format is one line instead of editing a 5-line find expression.

### 3c. Simplify color handling
The script defines `COLOR_RED`, `COLOR_ORANGE`, etc. as variables at the top, then loads the same colors from JSON in `load_config()`. The hardcoded values are overwritten by config anyway.

**Action:** Remove the hardcoded color definitions at the top. Let `load_config()` populate them exclusively from JSON.

---

## Phase 4 — Improve Variable Naming & Documentation

### 4a. Rename cryptic variables
| Current | Suggested | Reason |
|---------|-----------|--------|
| `_meta` | `media_meta` | Meaningless underscore prefix |
| `_skiplist` | `skip_codecs` | More descriptive |
| `_new_meta` | `output_meta` | Clearer context |

### 4b. Add section comments for new structure
After Phase 3 refactoring, add clear section headers:
```bash
# ============================================================================
# GPU SCHEDULING HELPERS
# ============================================================================
check_slot_available() { ... }
evaluate_gpu_headroom() { ... }
try_ooo_dispatch() { ... }

# ============================================================================
# MEDIA METADATA EXTRACTION
# ============================================================================
extract_media_metadata() { ... }
```

---

## Phase 5 — Performance Micro-Optimizations (Optional)

These are lower priority but could help with the 56K-video production dataset:

### 5a. Avoid repeated `df -m /dev/shm` calls
Currently called in both the slot-check loop and the scale-evaluation block. Cache the result or call less frequently.

### 5b. Reduce VCN sampling overhead
`get_vcn_utilization()` reads sysfs files on every sample. With `vcn_sample_interval=1`, this fires every second. Consider batching or caching.

### 5c. Use `mapfile` more efficiently in the main loop
Currently `mapfile -t videos < <(awk ...)` re-reads the entire CSV each restart. Could maintain an index into the file instead.

---

## Phase 6 — Refactor & Re-test

Execute Phases 1-4 in order, running the smoke regression test after **each** phase to confirm nothing regressed.

### Target outcomes
| Metric | Before | Target |
|--------|--------|--------|
| Script size | ~50 KB | ~38-42 KB |
| Lines of code | ~700 | ~500-560 |
| Function count | ~25 | ~30 (more, smaller functions) |
| Smoke test pass | FAIL | PASS |

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Refactoring breaks the subshell function scoping fix | Low | Test after Phase 1 before proceeding |
| Extracting shared functions changes return-value semantics | Medium | Keep `extract_media_metadata` returning same format |
| Splitting the main loop changes timing/behavior of OOO dispatch | Medium | Run smoke test with all 6 videos after each split |
| VCN sampling change affects GPU scaling decisions | Low | Keep interval configurable, test with real GPU if available |

---

## Execution Order

```
Phase 0: Baseline & regression test (establish pass criteria)
    ↓
Phase 1: Fix background subshell bug (correctness fix)
    ↓ [re-run regression]
Phase 2: Eliminate duplication (dedup metadata, cleanup, skip writing)
    ↓ [re-run regression]
Phase 3: Simplify logic blocks (extract GPU helpers, format array, remove hardcoded colors)
    ↓ [re-run regression]
Phase 4: Variable naming & documentation
    ↓ [re-run regression]
Phase 5: Performance micro-optimizations (optional, lower priority)
```

---

## Notes on the Known Bug

The regression log shows:
```
./transcode.sh: line 827: run_media_scan: command not found
```

This happens because the scan block uses `( ... ) &` to background the scan+merge. Bash subshells created with `(...)` do **not** inherit functions from the parent shell — only exported functions are available. This is a real bug that prevents background scanning from working. Phase 1 fixes this before any other refactoring begins, ensuring we're optimizing a working script rather than a broken one.
