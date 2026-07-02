#!/usr/bin/env bash
#
# FFmpeg Video Transcoding Script
# ============================================================================
# Orchestrates hardware-accelerated AV1 video transcoding with VAAPI.
# Sources: lib/config.sh, lib/logging.sh, lib/media.sh, lib/scan.sh,
#          lib/process.sh, lib/transcode.sh, lib/scheduler.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Color constants (hardcoded — the JSON "colors" section is legacy/unused)
# ---------------------------------------------------------------------------
COLOR_RED="\033[1;91m"
COLOR_ORANGE="\033[0;33m"
COLOR_YELLOW="\033[1;93m"
COLOR_GREEN="\033[1;92m"
COLOR_RESET="\033[0m"

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/media.sh"
source "$SCRIPT_DIR/lib/scan.sh"
source "$SCRIPT_DIR/lib/process.sh"
source "$SCRIPT_DIR/lib/transcode.sh"
source "$SCRIPT_DIR/lib/scheduler.sh"

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------
trap 'abort_handler INT' INT
trap 'abort_handler TERM' TERM
trap 'abort_handler HUP' HUP
trap cleanup_shm EXIT

# ============================================================================
# INITIALIZATION
# ============================================================================
check_dependencies
load_config "${1:-./transcode-config.json}"

# Global settings from config
SKIP_FILE=${CONFIG_GLOBAL["skip_file"]:-"./skip.csv"}
FFMPEG_VAAPI_DEVICE=${CONFIG_GLOBAL["ffmpeg_vaapi_device"]:-"/dev/dri/renderD128"}
MIN_THREADS=${CONFIG_GLOBAL["min_threads"]:-1}
MAX_THREADS=${CONFIG_GLOBAL["max_threads"]:-8}
GPU_TARGET_PCT=${CONFIG_GLOBAL["gpu_target_pct"]:-70}
GPU_RAMP_WAIT=${CONFIG_GLOBAL["gpu_ramp_wait"]:-10}
GPU_CHECK_INTERVAL=${CONFIG_GLOBAL["gpu_check_interval"]:-30}
GPU_HEADROOM_CONFIRM=${CONFIG_GLOBAL["gpu_headroom_confirm"]:-2}
VCN_SAMPLE_INTERVAL=${CONFIG_GLOBAL["vcn_sample_interval"]:-10}
FFMPEG_INPUT_PARAMS=${CONFIG_GLOBAL["ffmpeg_input_params"]:-""}
FFMPEG_LOGGING=${CONFIG_GLOBAL["ffmpeg_logging"]:-"error"}
FFMPEG_TIMEOUT=${CONFIG_GLOBAL["ffmpeg_timeout"]:-3600}
RESTART_QUEUE=${CONFIG_GLOBAL["restart_queue"]:-720}
SCAN_AT_START=${CONFIG_GLOBAL["scan_at_start"]:-0}
MOVE_FILE=${CONFIG_GLOBAL["move_file"]:-0}

# Time constants
DAYS_TO_SECONDS=86400
MINUTES_TO_SECONDS=60

# ============================================================================
# MAIN
# ============================================================================
main() {
    local SCAN_RESULTS="./scan_results.csv"
    local SCAN_RESULTS_TMP="./scan_results.tmp"

    initialize_output_folder
    show_state

    local need_scan=0
    if [[ $SCAN_AT_START -eq 1 ]]; then
        need_scan=1
    elif [[ ! -f "$SCAN_RESULTS" ]]; then
        need_scan=1
    fi

    if [[ $need_scan -eq 1 ]]; then
        for config_name in "${CONFIG_NAMES[@]}"; do
            run_media_scan "$config_name"
        done
        merge_scan_results "$SCAN_RESULTS"
    elif [[ -f "$SCAN_RESULTS" ]] && [[ $(wc -l <"$SCAN_RESULTS") -gt 0 ]]; then
        # Background re-scan: the main loop reads the existing results while
        # a background job refreshes them for the next restart cycle.
        (
            for config_name in "${CONFIG_NAMES[@]}"; do
                run_media_scan "$config_name"
            done
            merge_scan_results "$SCAN_RESULTS_TMP" && mv -f "$SCAN_RESULTS_TMP" "$SCAN_RESULTS"
        ) &
    else
        for config_name in "${CONFIG_NAMES[@]}"; do
            run_media_scan "$config_name"
        done
        merge_scan_results "$SCAN_RESULTS"
        if [[ ! -f "$SCAN_RESULTS" || $(wc -l <"$SCAN_RESULTS") -eq 0 ]]; then
            echo "[ERROR] No videos found after scan. Exiting."
            exit 1
        fi
    fi

    mapfile -t videos < <(awk -F, '{print $0}' "$SCAN_RESULTS")
    declare -gA skip_lookup
    load_skip_file

    # ========================================================================
    # PROCESSING LOOP
    # ========================================================================

    # Concurrency is governed by a live "headroom" grant from the status check
    # rather than a ratcheting slot count. Base slots (<= MIN_THREADS) always run;
    # extra slots fill only while gpu_has_headroom=1.
    declare -g gpu_has_headroom=0
    declare -g low_vcn_streak=0
    declare -gA dispatched_ooo

    local video_idx=0
    declare -g last_ooo_check=0
    local queue_timer
    queue_timer=$(date +%s)
    declare -g last_job_start=0
    declare -g last_scale_check=0
    declare -g last_status_log=0
    declare -g last_vcn_sample=0
    declare -g vcn_sample_sum=0
    declare -g vcn_sample_count=0
    local last_wait_log=0
    declare -g video_size_mb=0

    while [[ $video_idx -lt ${#videos[@]} ]]; do
        # Skip already-dispatched out-of-order entries
        if [[ -n "${dispatched_ooo[$video_idx]:-}" ]]; then
            video_idx=$((video_idx + 1))
            continue
        fi

        IFS=',' read -r config_name video size <<<"${videos[$video_idx]}"

        # --- Queue restart check ---
        if [[ $RESTART_QUEUE -ne 0 ]]; then
            local now elapsed_minutes
            now=$(date +%s)
            elapsed_minutes=$(( (now - queue_timer) / MINUTES_TO_SECONDS ))
            if [[ $elapsed_minutes -gt $RESTART_QUEUE ]]; then
                _restart_queue
                video_idx=0
                queue_timer=$(date +%s)
                continue
            fi
        fi

        # --- Skip-list check ---
        local video_basename="${video##*/}"
        if [[ -n "${skip_lookup[$video_basename]:-}" ]]; then
            video_idx=$((video_idx + 1))
            continue
        fi

        # --- File existence ---
        if [[ ! -f "$video" ]]; then
            write_log "[WARN] File no longer exists, skipping: $video_basename"
            video_idx=$((video_idx + 1))
            continue
        fi

        # --- Min-size gate (stop when we hit files below the threshold) ---
        local min_size video_size_mb
        min_size="${CONFIG_MIN_SIZE[$config_name]}"
        video_size_mb=$((size / 1024 / 1024))
        if [[ $video_size_mb -lt $min_size ]]; then
            write_log "HIT VIDEO SIZE LIMIT for config '$config_name' - waiting for running jobs to finish then quitting"
            wait_for_jobs
            exit 0
        fi

        # --- Age gate ---
        local video_age min_age
        video_age=$(get_video_age "$video")
        min_age="${CONFIG_MIN_AGE[$config_name]}"
        if [[ $video_age -lt $min_age ]]; then
            write_log "($((video_idx+1))) $video_basename ($video_size_mb MB, $video_age days old) too new, skipping"
            video_idx=$((video_idx + 1))
            continue
        fi

        # --- Codec skip-list check (lightweight: only fetches video codec) ---
        local pre_codec
        pre_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null || true)
        local video_codec_skip_list="${CONFIG_SKIP_LIST[$config_name]}"
        IFS=',' read -ra _skiplist <<<"$video_codec_skip_list"
        local _skip
        for _skip in "${_skiplist[@]}"; do
            if [[ "$pre_codec" == "$_skip" ]]; then
                write_log "($((video_idx+1))) $video_basename (${video_size_mb}MB, $pre_codec) in video codec skip list, skipping"
                write_skip "$video_basename" "codec-skip"
                skip_lookup["$video_basename"]="codec-skip"
                video_idx=$((video_idx + 1))
                continue 2
            fi
        done

        # --- Slot-filling loop ---
        while true; do
            now=$(date +%s)
            local done_flag=0

            for ((thread = 1; thread <= MAX_THREADS; thread++)); do
                local job_name="GPU_$thread"
                local pid_var="JOB_PID_$thread"
                local start_var="JOB_START_$thread"
                local pid="${!pid_var:-}"
                local start_time="${!start_var:-}"

                # Check running jobs: timeout stale ones
                if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
                    if [[ -n "${start_time:-}" ]] && (( (now - start_time) > FFMPEG_TIMEOUT * MINUTES_TO_SECONDS )); then
                        write_log "[WARN] $job_name timed out, killing PID $pid"
                        kill_tree "$pid"
                        wait "$pid" 2>/dev/null || true
                        unset "$pid_var"
                        unset "$start_var"
                    fi
                else
                    # Slot is free (job finished or never started)
                    if [[ -n "${pid:-}" ]]; then
                        unset "$pid_var"
                        unset "$start_var"
                        last_job_start=$now
                    fi

                    # Scale down by omission: base slots (<= MIN_THREADS) always refill;
                    # extra slots only fill while headroom is granted.
                    if [[ $thread -gt $MIN_THREADS && $gpu_has_headroom -ne 1 ]]; then
                        continue
                    fi

                    # Determine shm space available to this slot.
                    local shm_free_mb reserved_mb effective_free t t_pid_var t_pid t_size_var
                    shm_free_mb=$(df -m /dev/shm | awk 'NR==2 {print $4}')
                    reserved_mb=0
                    for ((t = 1; t <= MAX_THREADS; t++)); do
                        [[ $t -eq $thread ]] && continue
                        t_pid_var="JOB_PID_$t"
                        t_pid="${!t_pid_var:-}"
                        if [[ -n "$t_pid" ]] && kill -0 "$t_pid" 2>/dev/null; then
                            t_size_var="JOB_SIZE_$t"
                            reserved_mb=$((reserved_mb + ${!t_size_var:-0}))
                        fi
                    done
                    effective_free=$((shm_free_mb - reserved_mb))

                    # If other jobs are holding shm and there isn't room, try OOO or wait.
                    if [[ $reserved_mb -gt 0 && $effective_free -lt $video_size_mb ]]; then
                        if _try_ooo_dispatch "$thread" "$video_idx" "$effective_free" done_flag; then
                            break
                        fi
                        if [[ $((now - last_wait_log)) -ge $GPU_CHECK_INTERVAL ]]; then
                            write_log "[WAIT] /dev/shm ${effective_free}MB available, need ${video_size_mb}MB for $video_basename — waiting for space"
                            last_wait_log=$now
                        fi
                        break
                    fi

                    # Room available: dispatch the current video into this free slot.
                    run_job_transcode "$config_name" "$video" "[T${thread}]" "$size" &
                    local new_pid=$!
                    declare -g "$pid_var=$new_pid"
                    declare -g "$start_var=$(date +%s)"
                    declare -g "JOB_SIZE_$thread=$video_size_mb"
                    last_job_start=$now
                    gpu_has_headroom=0
                    low_vcn_streak=0
                    done_flag=1
                    break
                fi
            done

            if [[ $done_flag -eq 1 ]]; then
                break
            fi

            sleep "$WAIT_STEP"

            # --- VCN sampling ---
            if [[ $((now - last_vcn_sample)) -ge $VCN_SAMPLE_INTERVAL ]]; then
                vcn_sample_sum=$((vcn_sample_sum + $(get_vcn_utilization)))
                vcn_sample_count=$((vcn_sample_count + 1))
                last_vcn_sample=$now
            fi

            # --- Headroom evaluation ---
            _evaluate_headroom
        done

        video_idx=$((video_idx + 1))
    done

    # ========================================================================
    # CLEANUP AND EXIT
    # ========================================================================
    write_log "Queue complete, waiting for running jobs to finish then quitting"
    wait_for_jobs
    rm -f "$SKIP_FILE"
    write_log "Removed skip files - next run will process all files"
    write_log "Finished processing"
    sleep "$EXIT_SLEEP"
}

main "$@"
