#!/usr/bin/env bash
#
# FFmpeg Video Transcoding Script

set -euo pipefail

# Video processing settings
MEDIA_PATH="/var/mnt/videos/videos/movies" # no leading slash
MIN_VIDEO_SIZE=3000 # Minimum size in MB before quitting
MIN_VIDEO_AGE=60     # Minimum age of file to process (days)
FFMPEG_OUTPUT_PARAMS="-vf 'format=nv12,hwupload' -c:v av1_vaapi -c:a copy -b:v 5M -maxrate 10M -bufsize 10M -max_muxing_queue_size 9999"


THREADS=2 # How ffmpeg jobs at same time
FFMPEG_INPUT_PARAMS="-err_detect ignore_err -ignore_unknown -vaapi_device /dev/dri/renderD128"
# FFMPEG_OUTPUT_PARAMS="-vf 'format=nv12,hwupload' -c:v av1_vaapi -c:a copy -b:v 5M -maxrate 10M -bufsize 10M -max_muxing_queue_size 9999"
# FFMPEG_OUTPUT_PARAMS="-vf 'format=nv12,hwupload' -c:v av1_vaapi -rc_mode CQP -qp 22 -quality 2 -c:a copy -max_muxing_queue_size 9999"

SCAN_AT_START=0             # 0 = use previous results and run background scan, 1 = force scan and wait for results
RESTART_QUEUE=720           # Minutes before re-doing the scan and start going through the queue again
FFMPEG_LOGGING="quiet"      # ffmpeg log level
FFMPEG_TIMEOUT=6000         # Timeout on job (minutes)
FFMPEG_MIN_DIFF=10          # Must be at least this much smaller (percentage)
FFMPEG_MAX_DIFF=99          # Must not save more than this (percentage)
VIDEO_CODEC_SKIP_LIST="av1,hevc" # Comma-separated list of video codecs to skip
MOVE_FILE=1                 # Set to 0 for testing (check ./output directory)

# Constants for magic numbers
DAYS_TO_SECONDS=86400      # Seconds in a day (24 * 60 * 60)
MINUTES_TO_SECONDS=60      # Seconds in a minute
FFMPEG_NICE_PRIORITY=15    # Nice priority level for ffmpeg processes
DURATION_TOLERANCE=10      # Tolerance in seconds for duration checks (±10 seconds)
SLEEP_BEFORE_CODEC_CHECK=1 # Sleep duration when skipping codec
SLEEP_BEFORE_MOVE=5        # Sleep duration before moving file
SLEEP_AFTER_MOVE=2         # Sleep duration after moving file

# ANSI Color codes for terminal output
COLOR_RED='\033[1;91m'    # Bold bright red for errors/warnings (brightest)
COLOR_ORANGE='\033[0;33m' # Orange for warnings (darker orange)
COLOR_YELLOW='\033[1;93m' # Bold bright yellow for success (brightest)
COLOR_GREEN='\033[1;92m'  # Bold bright green for info (brightest)
COLOR_RESET='\033[0m'     # Reset color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

write_log() {
    local log_string="$1"
    local log_file="./transcode.log"
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
    echo "$video_name" >>"./skip.txt"
}

write_skip_error() {
    local video_name="$1"
    echo "$video_name" >>"./skiperror.txt"
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
    skipped_count=$(wc -l <"./skip.txt" 2>/dev/null || echo 0)
    local skippederror_count
    skippederror_count=$(wc -l <"./skiperror.txt" 2>/dev/null || echo 0)
    local skiptotal_count
    skiptotal_count=$((skipped_count + skippederror_count))
    write_log "Started processing on $HOSTNAME"
    echo ""
    echo "  Previously processed files: $skipped_count"
    echo "  Previously errored files: $skippederror_count"
    echo "  Total files to skip: $skiptotal_count"
    echo "  Settings - Min Age: $MIN_VIDEO_AGE, Min Size: $MIN_VIDEO_SIZE, Threads: $THREADS, Timeout: $FFMPEG_TIMEOUT, Restart Queue: $RESTART_QUEUE"
    echo "  ffmpeg output params: $FFMPEG_OUTPUT_PARAMS"
    echo ""
}

run_media_scan() {
    local output_csv="$1"
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
        local ffmpeg_cmd="ffmpeg -y \
        $FFMPEG_INPUT_PARAMS \
        -v $FFMPEG_LOGGING \
        -i \"$video_path\" \
        $FFMPEG_OUTPUT_PARAMS \
        \"$output_path\""

        # Start ffmpeg in background and monitor size with low priority
        # echo "Running ffmpeg command: $ffmpeg_cmd"
        eval "nice -n $FFMPEG_NICE_PRIORITY $ffmpeg_cmd" &
        local ffmpeg_pid=$!

        # Start size monitoring in background
        monitor_output_size "$output_path" "$video_size" "$ffmpeg_pid" "$job" "$video_name" &
        local monitor_pid=$!

        # Wait for ffmpeg to complete
        if wait "$ffmpeg_pid"; then
            # Kill the monitor process since ffmpeg completed successfully
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true
            # Clean up any monitor flag file
            rm -f "/tmp/monitor_kill_${ffmpeg_pid}" 2>/dev/null || true
            # Post-transcode checks
            post_transcode_checks "$video_path" "$output_path" "$video_name" "$video_codec" "$audio_codec" "$video_duration" "$video_size" "$job" "$start_time"
        else
            # ffmpeg failed or was killed by monitor - check for monitor flag file
            local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
            local monitor_killed_ffmpeg=0
            
            if [[ -f "$monitor_flag" ]]; then
                # Monitor created flag file, so it killed ffmpeg
                monitor_killed_ffmpeg=1
                rm -f "$monitor_flag" 2>/dev/null || true
            fi
            
            # Clean up monitor process
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true

            if [[ $monitor_killed_ffmpeg -eq 1 ]]; then
                write_log "$job $video_name ERROR: ffmpeg killed by monitor (output larger than original)"
            else
                write_log "$job $video_name ERROR: ffmpeg command failed or crashed"
            fi
            write_skip_error "$video_name"
            # Clean up job folder on failure
            cleanup_job_folder "$output_path"
            return 1
        fi
    else
        write_log "$job $video_name ($video_codec, $video_size MB, $video_age days old) too new, skipping"
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

    # Create a flag file to indicate monitor killed ffmpeg
    local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
    
    # Monitor every 10 seconds
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        sleep 10
        if [[ -f "$output_path" ]]; then
            local current_size_mb
            current_size_mb=$(du -m "$output_path" | awk '{print $1}')
            if [[ $current_size_mb -gt $original_size_mb ]]; then
                write_log "$job $video_name WARN: Output file ($current_size_mb MB) is larger than original ($original_size_mb MB), killing transcode"
                # Create flag file before killing
                touch "$monitor_flag"
                kill -TERM "$ffmpeg_pid" 2>/dev/null || true
                sleep 5
                kill -9 "$ffmpeg_pid" 2>/dev/null || true
                return 1
            fi
        fi
    done
    # Clean up flag file if we exit normally
    rm -f "$monitor_flag" 2>/dev/null || true
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

# Show initial state
show_state

# Setup temp output folder, and clear previous transcodes
initialize_output_folder

# Get Videos - run Scan job at MEDIA_PATH or retrieve videos from scan_results.csv
SCAN_RESULTS="./scan_results.csv"
SCAN_RESULTS_TMP="./scan_results.tmp"
if [[ $SCAN_AT_START -eq 1 || ! -f "$SCAN_RESULTS" ]]; then
    run_media_scan "$SCAN_RESULTS"
elif [[ $SCAN_AT_START -eq 0 ]]; then
    # Only run scan in background if scan_results.csv exists and has at least 1 line
    if [[ -f "$SCAN_RESULTS" && $(wc -l <"$SCAN_RESULTS") -ge 1 ]]; then
        (run_media_scan "$SCAN_RESULTS_TMP" && mv -f "$SCAN_RESULTS_TMP" "$SCAN_RESULTS") &
    else
        run_media_scan "$SCAN_RESULTS"
        # After foreground scan, check again for results
        if [[ ! -f "$SCAN_RESULTS" || $(wc -l <"$SCAN_RESULTS") -eq 0 ]]; then
            echo "[ERROR] No videos found after scan. Exiting."
            exit 1
        fi
    fi
fi

mapfile -t videos < <(awk -F, '{print $1}' "$SCAN_RESULTS")

# Get previously skipped files from skip.txt and skiperror.txt
SKIP_FILE="./skip.txt"
SKIPERROR_FILE="./skiperror.txt"
declare -A skip_lookup
# Build associative array for O(1) lookups
if [[ -f "$SKIP_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && skip_lookup["$line"]=1
    done < "$SKIP_FILE"
fi
if [[ -f "$SKIPERROR_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && skip_lookup["$line"]=1
    done < "$SKIPERROR_FILE"
fi

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
        # Rebuild skip lookup hash table
        unset skip_lookup
        declare -A skip_lookup
        if [[ -f "$SKIP_FILE" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && skip_lookup["$line"]=1
            done < "$SKIP_FILE"
        fi
        if [[ -f "$SKIPERROR_FILE" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && skip_lookup["$line"]=1
            done < "$SKIPERROR_FILE"
        fi
        queue_timer=$(date +%s)
    fi

    # Skip if in skip list - O(1) lookup
    video_basename="$(basename "$video")"
    [[ -n "${skip_lookup[$video_basename]:-}" ]] && continue

    # Check min video size (in MB)
    video_size_mb=$(du -m "$video" | awk '{print $1}')
    if [[ $video_size_mb -lt $MIN_VIDEO_SIZE ]]; then
        write_log "HIT VIDEO SIZE LIMIT - waiting for running jobs to finish then quitting"
        exit 0
    fi

    # Job management loop (thread pool)
    while true; do
        done_flag=0
        for ((thread = 1; thread <= THREADS; thread++)); do
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
        sleep 1  # Brief pause to avoid tight loop
    done
done

# ============================================================================
# CLEANUP AND EXIT
# ============================================================================

write_log "Queue complete, waiting for running jobs to finish then quitting"
for ((thread = 1; thread <= THREADS; thread++)); do
    pid_var="JOB_PID_$thread"
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
    fi
done

write_log "Finished processing on bazzite"
exit 0
