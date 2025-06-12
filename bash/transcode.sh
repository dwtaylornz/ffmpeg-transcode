#!/usr/bin/env bash
#
# FFmpeg Video Transcoding Script
# 
# This script processes video files using hardware-accelerated AV1 encoding
# with VAAPI. It scans a directory for video files, transcodes them using
# multiple GPU threads, and manages the process with skip lists and error
# handling.
#
# Features:
# - Hardware-accelerated AV1 encoding with VAAPI
# - Multi-threaded processing with configurable GPU threads
# - Skip lists for processed and errored files
# - Size and duration validation
# - Automatic queue restart and timeout handling
#
# Transcode script for Linux using ffmpeg

set -euo pipefail

# Video processing settings
MEDIA_PATH="/var/mnt/videos" # no trailing slash
MIN_VIDEO_SIZE=3000 # Minimum size in MB before quitting
MIN_VIDEO_AGE=30     # Minimum age of file to process (days)

LOG_PATH="."
GPU_THREADS=2 # How many GPU jobs at same time

SCAN_AT_START=1 # 0 = get previous results and run background scan, 1 = force scan and wait for results, 2 = get results no scan
RESTART_QUEUE=720           # Minutes before re-doing the scan and start going through the queue again
FFMPEG_LOGGING="quiet"      # ffmpeg log level
FFMPEG_TIMEOUT=6000         # Timeout on job (minutes)
FFMPEG_MIN_DIFF=10          # Must be at least this much smaller (percentage)
FFMPEG_MAX_DIFF=99          # Must not save more than this (percentage)
VIDEO_CODEC_SKIP_LIST="av1" # Comma-separated list of video codecs to skip
MOVE_FILE=1                 # Set to 0 for testing (check ./output directory)

# Constants for magic numbers
DAYS_TO_SECONDS=86400       # Seconds in a day (24 * 60 * 60)
MINUTES_TO_SECONDS=60       # Seconds in a minute
FFMPEG_NICE_PRIORITY=15     # Nice priority level for ffmpeg processes
DURATION_TOLERANCE=10       # Tolerance in seconds for duration checks (±10 seconds)
SLEEP_BEFORE_CODEC_CHECK=1  # Sleep duration when skipping codec
SLEEP_BEFORE_MOVE=5         # Sleep duration before moving file
SLEEP_AFTER_MOVE=2          # Sleep duration after moving file

# ANSI Color codes for terminal output
COLOR_RED='\033[1;91m'      # Bold bright red for errors/warnings (brightest)
COLOR_ORANGE='\033[0;33m'   # Orange for warnings (darker orange)
COLOR_YELLOW='\033[1;93m'   # Bold bright yellow for success (brightest)
COLOR_GREEN='\033[1;92m'    # Bold bright green for info (brightest)
COLOR_RESET='\033[0m'       # Reset color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

write_log() {
    local log_string="$1"
    local log_file="$LOG_PATH/transcode.log"
    local stamp
    stamp="$(date '+%y/%m/%d %H:%M:%S')"
    local log_message="$stamp $log_string"
    # Color messages in terminal
    if [[ "$log_message" == *"ERROR"* ]]; then
        echo -e "${COLOR_RED}$log_message${COLOR_RESET}" # Red
    elif [[ "$log_message" == *"WARN"* ]]; then
        echo -e "${COLOR_ORANGE}$log_message${COLOR_RESET}" # Bright Orange
    elif [[ "$log_message" == *"SUCCESS"* ]]; then
        echo -e "${COLOR_YELLOW}$log_message${COLOR_RESET}" # Bright Yellow
    elif [[ "$log_message" == *"INFO"* ]]; then
        echo -e "${COLOR_GREEN}$log_message${COLOR_RESET}" # Green
    else
        echo "$log_message"
    fi
    echo "$log_message" >>"$log_file"
}

write_skip() {
    local video_name="$1"
    echo "$video_name" >>"$LOG_PATH/skip.txt"
}

write_skip_error() {
    local video_name="$1"
    echo "$video_name" >>"$LOG_PATH/skiperror.txt"
}

initialize_output_folder() {
    local output_path="/dev/shm/ffmpeg-transcode"
    if [[ ! -d "$output_path" ]]; then
        mkdir -p "$output_path"
    else
        rm -rf "${output_path:?}"/*
    fi
}

# ============================================================================
# MEDIA PROCESSING FUNCTIONS
# ============================================================================

get_video_age() {
    local video_path="$1"
    local ctime
    ctime=$(stat -c %Y "$video_path")
    local now
    now=$(date +%s)
    echo $(((now - ctime) / DAYS_TO_SECONDS))
}

get_media_info() {
    local video_path="$1"
    ffprobe -v quiet -print_format json -show_streams -show_format "$video_path"
}

show_state() {
    local skipped_count
    skipped_count=$(wc -l <"$LOG_PATH/skip.txt" 2>/dev/null || echo 0)
    local skippederror_count
    skippederror_count=$(wc -l <"$LOG_PATH/skiperror.txt" 2>/dev/null || echo 0)
    local skiptotal_count
    skiptotal_count=$((skipped_count + skippederror_count))
    echo ""
    echo "  Previously processed files: $skipped_count"
    echo "  Previously errored files: $skippederror_count"
    echo "  Total files to skip: $skiptotal_count"
    echo "  Settings - Min Age: $MIN_VIDEO_AGE, Min Size: $MIN_VIDEO_SIZE, Threads: $GPU_THREADS, Timeout: $FFMPEG_TIMEOUT, Restart Queue: $RESTART_QUEUE"
    echo ""
}

set_ffmpeg_low_priority() {
    local pids
    pids=$(pgrep ffmpeg 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        while read -r pid; do
            local current_nice
            current_nice=$(ps -o ni= -p "$pid" 2>/dev/null || echo "")
            if [[ -n "$current_nice" && "$current_nice" != "$FFMPEG_NICE_PRIORITY" ]]; then
                renice +$FFMPEG_NICE_PRIORITY "$pid" >/dev/null 2>&1 || true
            fi
        done <<<"$pids"
    fi
}

run_media_scan() {
    local output_csv="$LOG_PATH/scan_results.csv"
    : >"$output_csv"
    find "$MEDIA_PATH" -type f \
        \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.mov' -o -iname '*.y4m' -o -iname '*.m2ts' -o -iname '*.mp4' -o -iname '*.wmv' \) \
        -printf '%p,%s\n' | sort -t, -k2 -nr >"$output_csv"
}

# ============================================================================
# TRANSCODING FUNCTIONS
# ============================================================================

run_job_transcode() {
    local video_path="$2"
    local job="$3"

    local video_name
    video_name="$(basename "$video_path")"
    local video_size
    video_size=$(du -m "$video_path" | awk '{print $1}')

    local media_info_json
    media_info_json=$(get_media_info "$video_path")
    local video_codec
    video_codec=$(echo "$media_info_json" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name' | head -n1)
    local video_age
    video_age=$(get_video_age "$video_path")

    # Initialize variables and parse skip list
    local skip_codec=0
    local skiplist=()
    IFS=',' read -ra skiplist <<<"$VIDEO_CODEC_SKIP_LIST"

    # Check if video codec is in skip list
    for skip in "${skiplist[@]}"; do
        if [[ "$video_codec" == "$skip" ]]; then
            write_log "$job $video_name (${video_size}MB,$video_codec) in video codec skip list, skipping"
            write_skip "$video_name"
            skip_codec=1
            sleep $SLEEP_BEFORE_CODEC_CHECK
            break
        fi
    done
    
    # Add early return for skip case to avoid duplicate logging
    if [[ $skip_codec -eq 1 ]]; then
        return 0
    fi
    
    if [[ $video_age -ge $MIN_VIDEO_AGE ]]; then
        local audio_codec
        audio_codec=$(echo "$media_info_json" | jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' | head -n1)
        local audio_channels
        audio_channels=$(echo "$media_info_json" | jq -r '.streams[] | select(.codec_type=="audio") | .channels' | head -n1)
        local video_width
        video_width=$(echo "$media_info_json" | jq -r '.streams[] | select(.codec_type=="video") | .width' | head -n1)
        local video_duration
        video_duration=$(echo "$media_info_json" | jq -r '.format.duration' | awk '{print int($1)}')
        local start_time
        start_time=$(date +%s)
        # write_skip "$video_name"
        write_log "$job $video_name ($video_codec, $audio_codec($audio_channels channel), $video_width, ${video_size}MB, $video_age days old) transcoding..."
        # Create job-specific folder and output path
        local job_folder="/dev/shm/ffmpeg-transcode/job_${job//[()]/}"
        local output_path="$job_folder/$video_name"
        
        # Clean up any existing job folder before starting
        if [[ -d "$job_folder" ]]; then
            rm -rf "$job_folder"
        fi
        mkdir -p "$job_folder"

        # Build ffmpeg command
        local ffmpeg_cmd="ffmpeg -y -err_detect ignore_err -ignore_unknown -vaapi_device /dev/dri/renderD128 -v $FFMPEG_LOGGING \
    -i \"$video_path\" \
    -vf 'format=nv12,hwupload' -c:v av1_vaapi -c:a copy \
    -b:v 3M -maxrate 5M -bufsize 5M \
    -max_muxing_queue_size 9999 \
    \"$output_path\""

        # Start ffmpeg in background and monitor size
        eval "$ffmpeg_cmd" &
        local ffmpeg_pid=$!
        
        # Start size monitoring in background
        monitor_output_size "$output_path" "$video_size" "$ffmpeg_pid" "$job" "$video_name" &
        local monitor_pid=$!
        
        # Wait for ffmpeg to complete
        if wait "$ffmpeg_pid"; then
            # Kill the monitor process since ffmpeg completed successfully
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true
            # Post-transcode checks
            post_transcode_checks "$video_path" "$output_path" "$video_name" "$video_codec" "$audio_codec" "$video_duration" "$video_size" "$job" "$start_time"
        else
            # ffmpeg failed or was killed by monitor
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true
            write_log "$job $video_name ERROR: ffmpeg command failed or was cancelled"
            write_skip_error "$video_name"
            # Clean up job folder on failure
            cleanup_job_folder "$output_path"
            return 1
        fi
    else
        write_log "$video_name ($video_codec, $video_size MB, $video_age days old) in video codec skip list or too new, skipping"
        write_skip "$video_name"
        return 0
    fi
}

# ============================================================================
# POST-PROCESSING FUNCTIONS
# ============================================================================

cleanup_job_folder() {
    local output_path="$1"
    local job_folder
    job_folder=$(dirname "$output_path")
    if [[ -d "$job_folder" && "$job_folder" == *"/dev/shm/ffmpeg-transcode/"* ]]; then
        rm -rf "$job_folder"
    fi
}

monitor_output_size() {
    local output_path="$1"
    local original_size_mb="$2"
    local ffmpeg_pid="$3"
    local job="$4"
    local video_name="$5"
    
    # Monitor every 10 seconds
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        sleep 10
        if [[ -f "$output_path" ]]; then
            local current_size_mb
            current_size_mb=$(du -m "$output_path" | awk '{print $1}')
            if [[ $current_size_mb -gt $original_size_mb ]]; then
                write_log "$job $video_name WARN: Output file ($current_size_mb MB) is larger than original ($original_size_mb MB), killing transcode"
                kill -TERM "$ffmpeg_pid" 2>/dev/null || true
                sleep 5
                kill -9 "$ffmpeg_pid" 2>/dev/null || true
                return 1
            fi
        fi
    done
    return 0
}

post_transcode_checks() {
    local video_path="$1"
    local output_path="$2"
    local video_name="$3"
    local video_codec="$4"
    local audio_codec="$5"
    local video_duration="$6"
    local video_size_mb="$7"
    local job="$8"
    local start_time="$9"
    # Use global variables for move_file and min/max diff
    local move_file="$MOVE_FILE"
    local ffmpeg_min_diff="$FFMPEG_MIN_DIFF"
    local ffmpeg_max_diff="$FFMPEG_MAX_DIFF"

    # Check new file exists
    if [[ ! -f "$output_path" ]]; then
        write_log "$job $video_name ERROR or FAILED - output not found"
        write_log "$job $video_name ERROR cannot find $output_path"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Check size of new file
    local video_new_size_mb
    video_new_size_mb=$(du -m "$output_path" | awk '{print $1}')
    if [[ "$video_new_size_mb" -eq 0 ]]; then
        write_log "$job $video_name ERROR, zero file size (${video_new_size_mb}MB), File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Get new media info
    local new_media_info_json
    new_media_info_json=$(get_media_info "$output_path")
    local video_new_duration
    video_new_duration=$(echo "$new_media_info_json" | jq -r '.format.duration' | awk '{print int($1)}')
    local video_new_videocodec
    video_new_videocodec=$(echo "$new_media_info_json" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name' | head -n1)
    local video_new_audiocodec
    video_new_audiocodec=$(echo "$new_media_info_json" | jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' | head -n1)

    # Duration check (±10 seconds)
    if [[ -z "$video_new_duration" || $video_new_duration -lt $((video_duration - DURATION_TOLERANCE)) || $video_new_duration -gt $((video_duration + DURATION_TOLERANCE)) ]]; then
        write_log "$job $video_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Video stream check
    if [[ -z "$video_new_videocodec" || "$video_new_videocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no video stream detected, File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Audio stream check
    if [[ -z "$video_new_audiocodec" || "$video_new_audiocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no audio stream detected, File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Size difference checks
    local diff_mb diff_percent
    diff_mb=$((video_size_mb - video_new_size_mb))
    if [[ $video_size_mb -eq 0 ]]; then
        diff_percent=0
    else
        diff_percent=$(((video_size_mb - video_new_size_mb) * 100 / video_size_mb))
    fi

    # Check if output is larger than original (shouldn't happen with monitoring, but double-check)
    if [[ $video_new_size_mb -gt $video_size_mb ]]; then
        write_log "$job $video_name ERROR, output larger than original (${video_size_mb}MB -> ${video_new_size_mb}MB), File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    if [[ $diff_percent -lt $ffmpeg_min_diff ]]; then
        write_log "$job $video_name ERROR, min difference too small (${diff_percent}% < ${ffmpeg_min_diff}%) $video_size_mb MB -> $video_new_size_mb MB, File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi
    if [[ $diff_percent -gt $ffmpeg_max_diff ]]; then
        write_log "$job $video_name ERROR, max too high (${diff_percent}% > ${ffmpeg_max_diff}%) ${video_size_mb}MB -> ${video_new_size_mb}MB, File NOT moved"
        write_skip_error "$video_name"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Success: log and move if enabled
    local end_time total_time_formatted
    end_time=$(date +%s)
    local time_taken=$((end_time - start_time))
    local time_mins=$((time_taken / MINUTES_TO_SECONDS))
    local time_secs=$((time_taken % MINUTES_TO_SECONDS))
    total_time_formatted="${time_mins}:${time_secs}"
    local gb_per_minute=0
    if [[ $time_taken -gt 0 ]]; then
        gb_per_minute=$(awk "BEGIN {printf \"%.2f\", $video_size_mb/1024/($time_taken/$MINUTES_TO_SECONDS)}")
    fi

    if [[ $move_file -eq 0 ]]; then
        write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name INFO, move file disabled, File NOT moved"
    else
        write_log "$job $video_name Transcode time: $total_time_formatted (${gb_per_minute}GB/m), Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
        write_log "$job $video_name SUCCESS, moving file (DO NOT BREAK DURING MOVE)..."
        sleep $SLEEP_BEFORE_MOVE
        mv -f "$output_path" "$video_path"
        write_skip "$video_name"
        sleep $SLEEP_AFTER_MOVE
        # Clean up job-specific folder
        cleanup_job_folder "$output_path"
    fi
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Setup temp output folder, and clear previous transcodes
initialize_output_folder

# Get Videos - run Scan job at MEDIA_PATH or retrieve videos from scan_results.csv
SCAN_RESULTS="$LOG_PATH/scan_results.csv"
if [[ $SCAN_AT_START -eq 1 || ! -f "$SCAN_RESULTS" ]]; then
    run_media_scan
elif [[ $SCAN_AT_START -eq 0 ]]; then
    # Run scan in background to update results for next run
    run_media_scan &
fi

mapfile -t videos < <(awk -F, '{print $1}' "$SCAN_RESULTS")

# Get previously skipped files from skip.txt and skiperror.txt
SKIP_FILE="$LOG_PATH/skip.txt"
SKIPERROR_FILE="$LOG_PATH/skiperror.txt"
skipped_files=()
skippederror_files=()
[[ -f "$SKIP_FILE" ]] && mapfile -t skipped_files <"$SKIP_FILE"
[[ -f "$SKIPERROR_FILE" ]] && mapfile -t skippederror_files <"$SKIPERROR_FILE"
skiptotal_files=("${skipped_files[@]}" "${skippederror_files[@]}")

# Show settings and any jobs running
show_state

# ============================================================================
# MAIN PROCESSING LOOP
# ============================================================================

# Main Loop across videos
queue_timer=$(date +%s)
for video in "${videos[@]}"; do
    # If duration has exceeded queue timer then re-run the scan
    now=$(date +%s)
    duration=$(((now - queue_timer) / MINUTES_TO_SECONDS))
    if [[ $RESTART_QUEUE -ne 0 && $duration -gt $RESTART_QUEUE ]]; then
        run_media_scan
        mapfile -t videos < <(awk -F, '{print $1}' "$SCAN_RESULTS")
        [[ -f "$SKIP_FILE" ]] && mapfile -t skipped_files <"$SKIP_FILE"
        [[ -f "$SKIPERROR_FILE" ]] && mapfile -t skippederror_files <"$SKIPERROR_FILE"
        skiptotal_files=("${skipped_files[@]}" "${skippederror_files[@]}")
        queue_timer=$(date +%s)
    fi

    # Skip if in skip list
    skip=0
    for skipfile in "${skiptotal_files[@]}"; do
        [[ "$(basename "$video")" == "$skipfile" ]] && skip=1 && break
    done
    [[ $skip -eq 1 ]] && continue

    # Check min video size (in MB)
    video_size_mb=$(du -m "$video" | awk '{print $1}')
    if [[ $video_size_mb -lt $MIN_VIDEO_SIZE ]]; then
        write_log "HIT VIDEO SIZE LIMIT - waiting for running jobs to finish then quitting"
        exit 0
    fi

    # Job management loop (thread pool)
    while true; do
        done_flag=0
        for ((thread = 1; thread <= GPU_THREADS; thread++)); do
            job_name="GPU_$thread"
            pid_var="JOB_PID_$thread"
            start_var="JOB_START_$thread"
            pid="${!pid_var:-}"
            start_time="${!start_var:-}"

            # Check if job is running
            if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
                # Check for timeout
                now="$(date +%s)"
                if [[ -n "${start_time:-}" ]] && (((now - start_time) > FFMPEG_TIMEOUT * MINUTES_TO_SECONDS)); then
                    echo "[WARN] $job_name timed out, killing PID $pid"
                    kill -9 "$pid" 2>/dev/null || true
                    wait "$pid" 2>/dev/null || true
                    unset $pid_var
                    unset $start_var
                fi
            else
                # Job is not running, start a new one
                run_job_transcode "." "$video" "($thread)" &
                new_pid=$!
                declare $pid_var=$new_pid
                declare $start_var="$(date +%s)"
                done_flag=1
                break
            fi
        done
        if [[ $done_flag -eq 1 ]]; then
            break
        fi
        set_ffmpeg_low_priority
    done
done

# ============================================================================
# CLEANUP AND EXIT
# ============================================================================

write_log "-----------Queue complete, waiting for running jobs to finish then quitting-----------"
for ((thread = 1; thread <= GPU_THREADS; thread++)); do
    pid_var="JOB_PID_$thread"
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
    fi
done

write_log "-----------exiting-----------"
exit 0
