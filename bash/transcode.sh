#!/usr/bin/env bash
#
# FFmpeg Video Transcoding Script
#
set -euo pipefail
# ============================================================================
# CONFIGURATION & ARGUMENTS
# ============================================================================
COLOR_RED="\033[1;91m"
COLOR_ORANGE="\033[0;33m"
COLOR_YELLOW="\033[1;93m"
COLOR_GREEN="\033[1;92m"
COLOR_RESET="\033[0m"

# UTILITY FUNCTIONS
# ============================================================================
check_dependencies() {
    for cmd in jq ffmpeg ffprobe; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERROR: $cmd is required but not installed. Please install it to continue."
            exit 1
        fi
    done
}

get_vcn_utilization() {
    for f in /sys/class/drm/card*/device/vcn_busy_percent; do
        [[ -r "$f" ]] && { cat "$f"; return; }
    done
    echo 0
}

load_config() {
    local config_file="${1:-./transcode-config.json}"
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file '$config_file' not found"
        exit 1
    fi
    if ! jq empty "$config_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in configuration file '$config_file'"
        exit 1
    fi

    # Load global settings
    declare -gA CONFIG_GLOBAL
    while IFS=$'\t' read -r key value; do
        [[ "$key" == "colors" ]] && continue
        CONFIG_GLOBAL["$key"]="$value"
    done < <(jq -r '.global_settings | to_entries | .[] | select(.value | type != "object") | "\(.key)\t\(.value)"' "$config_file")

    while IFS=$'\t' read -r key value; do
        CONFIG_GLOBAL["COLOR_$key"]="$value"
    done < <(jq -r '.global_settings.colors // {} | to_entries | .[] | "\(.key)\t\(.value)"' "$config_file")

    # Load configurations
    declare -gA CONFIG_MEDIA_PATH CONFIG_MIN_SIZE CONFIG_MIN_AGE CONFIG_FFMPEG_PARAMS CONFIG_SKIP_LIST
    mapfile -t CONFIG_NAMES < <(jq -r '.configurations[].name' "$config_file")
    while IFS=$'\t' read -r cfg_name path min_size min_age ffmpeg_params skip_list; do
        CONFIG_MEDIA_PATH["$cfg_name"]="$path"
        CONFIG_MIN_SIZE["$cfg_name"]="$min_size"
        CONFIG_MIN_AGE["$cfg_name"]="$min_age"
        CONFIG_FFMPEG_PARAMS["$cfg_name"]="$ffmpeg_params"
        CONFIG_SKIP_LIST["$cfg_name"]="$skip_list"
    done < <(jq -r '.configurations[] | [.name, .media_path, .min_video_size, .min_video_age, .ffmpeg_output_params, .video_codec_skip_list] | @tsv' "$config_file")

    # Initialize tunables from config so that JSON overrides take effect.
    # These were previously hardcoded; reading them here means a user
    # changing the JSON file actually changes behavior.
    FFMPEG_MIN_DIFF=${CONFIG_GLOBAL["ffmpeg_min_diff"]:-10}
    FFMPEG_MAX_DIFF=${CONFIG_GLOBAL["ffmpeg_max_diff"]:-95}
    FFMPEG_NICE_PRIORITY=${CONFIG_GLOBAL["ffmpeg_nice_priority"]:--20}
    DURATION_TOLERANCE=${CONFIG_GLOBAL["duration_tolerance"]:-30}
    SLEEP_BEFORE_MOVE=${CONFIG_GLOBAL["sleep_before_move"]:-2}
    SLEEP_AFTER_MOVE=${CONFIG_GLOBAL["sleep_after_move"]:-2}
}

# Color semantics used by write_log():
#   red    = ERROR
#   orange = WARN
#   yellow = SUCCESS
#   green  = INFO
write_log() {
    local log_string="$1"
    local level="${2:-}"
    local log_file="./transcode.log"
    local stamp
    stamp="$(date '+%y/%m/%d %H:%M:%S')"
    local log_message="$stamp $log_string"
    # Auto-detect level from message content when not explicitly provided
    if [[ -z "$level" ]]; then
        if [[ "$log_string" == *"ERROR"* ]]; then
            level="ERROR"
        elif [[ "$log_string" == *"WARN"* ]]; then
            level="WARN"
        elif [[ "$log_string" == *"SUCCESS"* ]]; then
            level="SUCCESS"
        elif [[ "$log_string" == *"INFO"* ]]; then
            level="INFO"
        fi
    fi
    case "$level" in
        ERROR)   echo -e "${COLOR_RED}$log_message${COLOR_RESET}" ;;
        WARN)    echo -e "${COLOR_ORANGE}$log_message${COLOR_RESET}" ;;
        SUCCESS) echo -e "${COLOR_YELLOW}$log_message${COLOR_RESET}" ;;
        INFO)    echo -e "${COLOR_GREEN}$log_message${COLOR_RESET}" ;;
        *)       echo "$log_message" ;;
    esac
    echo "$log_message" >>"$log_file"
}

write_skip() {
    local video_name="$1"
    local reason="${2:-transcoded}"
    if [[ -z "${skip_lookup[$video_name]:-}" ]]; then
        printf '%s,%s\n' "$video_name" "$reason" >>"$SKIP_FILE"
        skip_lookup["$video_name"]="$reason"
    fi
}

initialize_output_folder() {
    local output_path="${CONFIG_GLOBAL["output_path"]:-/dev/shm/ffmpeg-transcode}"
    rm -rf "${output_path:?}"
    mkdir -p "$output_path"
}

cleanup_shm() {
    local shm_path="/dev/shm/ffmpeg-transcode"
    [[ -d "$shm_path" ]] && rm -rf "$shm_path"
}

# Terminate a process and its entire descendant tree.
# Children are killed before their parent so the parent cannot respawn them.
# Uses pkill -P for direct children + SIGTERM/SIGKILL with grace period.
kill_tree() {
    local root="${1:-}"
    [[ -z "$root" ]] && return
    [[ "$root" == "$$" ]] && return   # never kill the main script itself
    if ! kill -0 "$root" 2>/dev/null; then
        return
    fi
    # SIGTERM children first, then root
    pkill -P "$root" 2>/dev/null || true
    kill -TERM "$root" 2>/dev/null || true
    # Grace period
    local waited=0
    while [[ $waited -lt 10 ]] && kill -0 "$root" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
    done
    # SIGKILL survivors
    pkill -9 -P "$root" 2>/dev/null || true
    kill -KILL "$root" 2>/dev/null || true
    wait "$root" 2>/dev/null || true
}

# Kill every running transcode job (the whole process tree: ffmpeg, monitor,
# progress sink, and the run_job_transcode subshell), clean up shared memory,
# clear the slot-tracking variables so the status counter drops to 0, and exit
# with a code that indicates the abort was intentional.
abort_handler() {
    local sig="${1:-INT}"
    local thread pid_var pid
    for ((thread = 1; thread <= MAX_THREADS; thread++)); do
        pid_var="JOB_PID_$thread"
        pid="${!pid_var:-}"
        if [[ -n "$pid" ]]; then
            kill_tree "$pid"
        fi
        unset "$pid_var" 2>/dev/null || true
        unset "JOB_START_$thread" 2>/dev/null || true
        unset "JOB_SIZE_$thread" 2>/dev/null || true
    done
    # cleanup_shm is handled by the EXIT trap
    # 128 + signal number: SIGINT=2, SIGTERM=15, SIGHUP=1
    case "$sig" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
        HUP) exit 129 ;;
        *) exit 137 ;;
    esac
}

trap 'abort_handler INT' INT
trap 'abort_handler TERM' TERM
trap 'abort_handler HUP' HUP
trap cleanup_shm EXIT

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

# Extract the target video bitrate (Mbps, integer) from a configuration's
# ffmpeg_output_params. Prefers -maxrate (peak) for a safe upper bound, then
# falls back to -b:v (average). Returns 5 if neither is present.
parse_bv() {
    local p="$1"
    local v num unit
    v=$(echo "$p" | grep -oE '\-maxrate[ =][0-9]+[kKmMgG]?' | grep -oE '[0-9]+[kKmMgG]?$')
    [[ -z "$v" ]] && v=$(echo "$p" | grep -oE '\-b:v[ =][0-9]+[kKmMgG]?' | grep -oE '[0-9]+[kKmMgG]?$')
    [[ -z "$v" ]] && { echo 5; return; }
    num=$(echo "$v" | grep -oE '^[0-9]+')
    unit=$(echo "$v" | grep -oE '[kKmMgG]$')
    case "$unit" in
        k|K) echo $(( num / 1000 )) ;;
        m|M) echo "$num" ;;
        g|G) echo $(( num * 1000 )) ;;
        *)   echo $(( num / 1000000 )) ;;
    esac
}

# Estimate the shm space (MB) a transcode job will need. Based on EXPECTED
# output size = duration(s) * target_bitrate(Mbps) / 8, with a safety margin.
# Falls back to the full source size when duration is unknown, and never
# reserves more than the source. This replaces the old behaviour of reserving
# the entire source size, which starved concurrency and under-fed the GPU.
calc_reserve() {
    local cfg="$1" sz_mb="$2" dur="$3"
    local bv=${CONFIG_BV_MB[$cfg]:-5}
    local out=0
    if [[ -n "$dur" && "$dur" =~ ^[0-9]+$ && "$dur" -gt 0 ]]; then
        out=$(( dur * bv / 8 ))                         # MB at average target bitrate
        out=$(( out * ${SHM_RESERVE_SAFETY_PCT:-130} / 100 ))  # safety margin
        [[ $out -lt ${SHM_RESERVE_FLOOR_MB:-200} ]] && out=${SHM_RESERVE_FLOOR_MB:-200}
    else
        out=$sz_mb                                      # fallback: conservative source size
    fi
    [[ $out -gt $sz_mb ]] && out=$sz_mb                 # never exceed the source
    echo "$out"
}

get_media_info() {
    local video_path="$1"
    ffprobe -v quiet -print_format json -show_streams -show_format "$video_path"
}

show_state() {
    local skipped_count skippederror_count skiptotal_count
    skipped_count=$(grep -c ',transcoded\|,codec-skip' "$SKIP_FILE" 2>/dev/null || true)
    skipped_count=${skipped_count:-0}
    skiptotal_count=$(grep -c ',' "$SKIP_FILE" 2>/dev/null || true)
    skiptotal_count=${skiptotal_count:-0}
    skippederror_count=$((skiptotal_count - skipped_count))
    write_log "Started processing on $HOSTNAME"
    echo ""
    echo "  Previously processed files: $skipped_count"
    echo "  Previously errored files: $skippederror_count"
    echo "  Total files to skip: $skiptotal_count"
    echo "  Global Settings - Threads: ${MIN_THREADS}-${MAX_THREADS} (VCN target: ${GPU_TARGET_PCT}%), Timeout: $FFMPEG_TIMEOUT, Restart Queue: $RESTART_QUEUE"
    echo ""
    echo "  Loaded Configurations:"
    for config_name in "${CONFIG_NAMES[@]}"; do
        echo "    - $config_name:"
        echo "        Path: ${CONFIG_MEDIA_PATH[$config_name]}"
        echo "        Min Age: ${CONFIG_MIN_AGE[$config_name]} days, Min Size: ${CONFIG_MIN_SIZE[$config_name]} MB"
        echo "        Skip Codecs: ${CONFIG_SKIP_LIST[$config_name]}"
        echo "        FFmpeg Params: ${CONFIG_FFMPEG_PARAMS[$config_name]}"
    done
    echo ""
    echo "  $(ffmpeg -version | head -n 1)"
    echo ""
}

run_media_scan() {
    local config_name="$1"
    local media_path="${CONFIG_MEDIA_PATH[$config_name]}"
    local output_csv="./scan_results_${config_name}.csv"
    if [[ $SCAN_AT_START -eq 1 ]]; then
        write_log "[INFO] Running media scan for config '$config_name' at $media_path"
    fi
    : >"$output_csv"
    find "$media_path" -type f \
        \( -iname '*.3g2' -o -iname '*.3gp' -o -iname '*.asf' -o -iname '*.avi' -o -iname '*.dav' -o -iname '*.dirac' -o -iname '*.drc' -o -iname '*.flv' -o -iname '*.gxf' -o -iname '*.ismv' -o -iname '*.ivf' -o -iname '*.m4v' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.mp2' -o -iname '*.mp4' -o -iname '*.mpeg' -o -iname '*.mpegts' -o -iname '*.mpg' -o -iname '*.m2ts' -o -iname '*.mxf' -o -iname '*.nut' -o -iname '*.ogg' -o -iname '*.ogv' -o -iname '*.ps' -o -iname '*.rm' -o -iname '*.roq' -o -iname '*.swf' -o -iname '*.ts' -o -iname '*.vc1' -o -iname '*.viv' -o -iname '*.vob' -o -iname '*.webm' -o -iname '*.wm' -o -iname '*.wmv' -o -iname '*.wtv' -o -iname '*.y4m' \) \
        -printf '%p,%s\n' | sort -t, -k2 -nr >"$output_csv"
    if [[ $SCAN_AT_START -eq 1 ]]; then
        write_log "Media scan complete, found $(wc -l <"$output_csv") videos in '$config_name'"
    fi
}

merge_scan_results() {
    local merged_csv="$1"
    local temp_merged="./scan_results.tmp"
    : >"$temp_merged"
    for config_name in "${CONFIG_NAMES[@]}"; do
        local config_csv="./scan_results_${config_name}.csv"
        if [[ -f "$config_csv" ]] && [[ $(wc -l <"$config_csv") -gt 0 ]]; then
            while IFS=',' read -r video_path size; do
                echo "$config_name,$video_path,$size" >> "$temp_merged"
            done < "$config_csv"
        fi
    done
    if [[ -s "$temp_merged" ]]; then
        sort -t, -k3 -nr "$temp_merged" > "$merged_csv"
    else
        : > "$merged_csv"
    fi
    rm -f "$temp_merged"
    local total_videos
    total_videos=$(wc -l <"$merged_csv" 2>/dev/null || echo 0)
    if [[ $SCAN_AT_START -eq 1 && $total_videos -gt 0 ]]; then
        write_log "[INFO] Merged scan results: found $total_videos total videos across all configurations"
    fi
}

# ============================================================================
# TRANSCODING FUNCTIONS
# ============================================================================
run_job_transcode() {
    local config_name="$1"
    local video_path="$2"
    local job="$3"
    local scan_size_bytes="${4:-0}"
    local ffmpeg_output_params="${CONFIG_FFMPEG_PARAMS[$config_name]}"
    local video_name="${video_path##*/}"
    local video_size
    if [[ "$scan_size_bytes" -gt 0 ]]; then
        video_size=$((scan_size_bytes / 1024 / 1024))
    else
        video_size=$(stat --format=%s "$video_path" 2>/dev/null)
        video_size=$((video_size / 1024 / 1024))
    fi
    local media_info_json
    media_info_json=$(get_media_info "$video_path")
    local video_codec audio_codec audio_channels video_width video_duration_float video_duration_tag audio_stream_count
    local _meta
    _meta=$(echo "$media_info_json" | jq -r '
        [
            ([.streams[] | select(.codec_type=="video") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .channels] | first) // 0,
            ([.streams[] | select(.codec_type=="video") | .width] | first) // 0,
            (.format.duration) // 0,
            ([.streams[] | select(.codec_type=="video") | .tags.DURATION] | first) // "null",
            ([.streams[] | select(.codec_type=="audio")] | length)
        ] | map(tostring) | join(" ")
    ')
    read -r video_codec audio_codec audio_channels video_width video_duration_float video_duration_tag audio_stream_count <<< "$_meta"
    local video_duration=${video_duration_float%.*}
    if [[ "$video_duration_tag" != "null" && "$video_duration_tag" =~ ^([0-9]+):([0-9]+):([0-9]+) ]]; then
        local tag_duration=$(( 10#${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[2]}*60 + 10#${BASH_REMATCH[3]} ))
        [[ $tag_duration -gt 0 ]] && video_duration=$tag_duration
    fi
    local video_age
    video_age=$(get_video_age "$video_path")
    if [[ "${audio_stream_count:-0}" -eq 0 ]]; then
        write_log "$job $video_name ERROR: no audio streams detected, deleting source file"
        write_skip "$video_name" "no-audio-source"
        rm -f "$video_path"
        return 1
    fi
    local start_time
    start_time=$(date +%s)
    write_log "$job $video_name ($video_codec, $audio_codec($audio_channels channel), $video_width, ${video_size}MB, $video_age days old) transcoding..."
    
    local job_folder="/dev/shm/ffmpeg-transcode/job_$(echo "$job" | tr -d '[]()')"
    local output_path="$job_folder/$video_name"
    if [[ -d "$job_folder" ]]; then
        rm -rf "$job_folder"
    fi
    mkdir -p "$job_folder"
    local progress_file="/tmp/ffmpeg_progress_${BASHPID}"
    local ffmpeg_err_file="/tmp/ffmpeg_err_${BASHPID}"
    rm -f "$progress_file"

    local audio_map="-map 0:a?"
    local audio_codec_override=""
    if [[ "$audio_codec" == "null" ]]; then
        write_log "$job $video_name WARN: unidentified audio codec, re-encoding to AAC"
        audio_codec_override="-c:a aac -ac 2"
    fi
    # Build the command string for eval.  Use single-quote wrapping for paths
    # so that special characters ([, ], {, }, (, ), spaces) are preserved
    # through the eval layer.  Any single-quote in the path itself is escaped
    # by the standard bash pattern: end-quote, literal escaped quote, re-open.
    local _sq="'"  # helper for the escape pattern below
    local video_path_sq="'${video_path//$_sq/$_sq\\$_sq$_sq}'"
    local output_path_sq="'${output_path//$_sq/$_sq\\$_sq$_sq}'"
    local ffmpeg_err_file_sq="'${ffmpeg_err_file//$_sq/$_sq\\$_sq$_sq}'"
    local ffmpeg_cmd="ffmpeg -y \
        $FFMPEG_INPUT_PARAMS \
        -v $FFMPEG_LOGGING \
        -progress \"$progress_file\" \
        -i $video_path_sq \
        -map 0:v:0 $audio_map -map 0:s? -c:s copy \
        $ffmpeg_output_params \
        $audio_codec_override \
        $output_path_sq 2>$ffmpeg_err_file_sq"
    # Launch ffmpeg in a subshell that execs the encoder.  Because the subshell
    # replaces itself with ffmpeg (via exec), $! is the PID of the actual
    # encoder process, not an idle bash wrapper.  This makes kill/wait on the
    # PID reliable and prevents orphaned wrappers from keeping pipe fds open.
    (
        eval "exec nice -n $FFMPEG_NICE_PRIORITY $ffmpeg_cmd"
    ) &
    local ffmpeg_pid=$!
    monitor_progress "$progress_file" "$scan_size_bytes" "$ffmpeg_pid" "$job" "$video_name" "$video_duration" "$output_path" "$ffmpeg_err_file" &
    local monitor_pid=$!
    local monitor_rc=0
    wait "$monitor_pid" 2>/dev/null || monitor_rc=$?
    monitor_rc=${monitor_rc:-0}

    local ffmpeg_exit=0
    wait "$ffmpeg_pid" 2>/dev/null || ffmpeg_exit=$?
    ffmpeg_exit=${ffmpeg_exit:-0}

    if [[ $monitor_rc -eq 2 ]]; then
        # Monitor initiated an early abort; the monitor has already cleaned up
        # artifacts and returned a distinct exit code. Log the outcome, mark the
        # file as skipped, and return the abort code to the caller.
        write_log "$job $video_name INFO: transcode aborted early by monitor due to size inefficiency"
        write_skip "$video_name" "early-abort-size-inefficient"
        return 2
    elif [[ $ffmpeg_exit -eq 0 ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        rm -f "/tmp/monitor_kill_${ffmpeg_pid}" "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
        if ! post_transcode_checks "$video_path" "$output_path" "$video_name" "$video_codec" "$audio_codec" "$video_duration" "$video_size" "$job" "$start_time"; then
            return 1
        fi
    else
        local monitor_flag_content=""
        local ffmpeg_err_detail=""
        local monitor_killed_ffmpeg=0
        local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
        if [[ -f "$monitor_flag" ]]; then
            monitor_killed_ffmpeg=1
            monitor_flag_content=$(cat "$monitor_flag" 2>/dev/null || true)
            rm -f "$monitor_flag" 2>/dev/null || true
        fi
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        if [[ -s "$ffmpeg_err_file" ]]; then
            ffmpeg_err_detail=" — $(tail -1 "$ffmpeg_err_file" | tr -d '\n')"
        fi
        rm -f "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
        if [[ $monitor_killed_ffmpeg -eq 1 ]]; then
            case "$monitor_flag_content" in
                early-abort-10pct|output-too-large)
                    write_log "$job $video_name ERROR: ffmpeg killed by monitor (output larger than original or early abort)"
                    write_skip "$video_name" "killed-by-monitor"
                    ;;
                *)
                    write_log "$job $video_name ERROR: ffmpeg killed by monitor (output larger than original)"
                    write_skip "$video_name" "killed-by-monitor"
                    ;;
            esac
            cleanup_job_folder "$output_path"
            return 1
        else
            write_log "$job $video_name ERROR: ffmpeg failed (exit ${ffmpeg_exit})${ffmpeg_err_detail}"
            write_skip "$video_name" "ffmpeg-crash-${ffmpeg_exit}"
            cleanup_job_folder "$output_path"
            return 1
        fi
    fi
}

# ============================================================================
# EARLY ABORT AND CLEANUP HELPERS
# ============================================================================
cleanup_job_folder() {
    local output_path="$1"
    local job_folder
    job_folder=$(dirname "$output_path")
    local shm_base="${CONFIG_GLOBAL["output_path"]:-/dev/shm/ffmpeg-transcode}"
    if [[ -d "$job_folder" && "$job_folder" == "$shm_base/"* ]]; then
        rm -rf "$job_folder"
    fi
}

abort_early_cleanup() {
    local output_path="$1"
    local progress_file="$2"
    local ffmpeg_err_file="$3"
    local monitor_flag="$4"
    local ffmpeg_pid="${5:-}"

    # Ensure ffmpeg is gone (safety net when the caller's own kill sequence may
    # have raced or the PID was reused).
    if [[ -n "$ffmpeg_pid" ]] && kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
        wait "$ffmpeg_pid" 2>/dev/null || true
    fi

    # Remove the partially written output and its temporary job folder.
    cleanup_job_folder "$output_path"

    # Remove progress capture, error log, and monitor flag.
    rm -f "$progress_file" "$ffmpeg_err_file" "$monitor_flag" 2>/dev/null || true
}

# ============================================================================
# POST_PROCESSING FUNCTIONS
# ============================================================================
monitor_progress() {
    local progress_file="$1"
    local original_size_bytes="$2"
    local ffmpeg_pid="$3"
    local job="$4"
    local video_name="$5"
    local video_duration="$6"
    local output_path="${7:-}"
    local ffmpeg_err_file="${8:-}"
    local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
    local last_log_time=0
    local now

    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        sleep 5
        [[ ! -f "$progress_file" ]] && continue

        # Read the latest progress values in a single pass (avoids 6 separate grep invocations)
        local total_size out_time_us out_time_ms speed fps frame
        read -r total_size out_time_us out_time_ms speed fps frame <<<"$(awk -F= '
            /^total_size=/  { ts=$2 }
            /^out_time_us=/ { otu=$2 }
            /^out_time_ms=/ { otm=$2 }
            /^speed=/       { sp=$2 }
            /^fps=/         { f=$2 }
            /^frame=/       { fr=$2 }
            END { print ts+0, otu+0, otm+0, sp+0, f+0, fr+0 }
        ' "$progress_file" 2>/dev/null)"
        total_size=${total_size:-}
        out_time_us=${out_time_us:-}
        out_time_ms=${out_time_ms:-}
        speed=${speed:-}
        fps=${fps:-}
        frame=${frame:-}
        # FFmpeg's out_time_ms/out_time_us are both in microseconds. Normalize to seconds.
        local elapsed_us=""
        if [[ "$out_time_us" =~ ^[0-9]+$ && "$out_time_us" -gt 0 ]]; then
            elapsed_us=$out_time_us
        elif [[ "$out_time_ms" =~ ^[0-9]+$ && "$out_time_ms" -gt 0 ]]; then
            elapsed_us=$out_time_ms
        fi
        local elapsed_sec=""
        if [[ -n "$elapsed_us" ]]; then
            elapsed_sec=$((elapsed_us / 1000000))
        fi

        # Early-abort condition: at 10% of playback time the output should be
        # well under 10% of the original file size. Once past 10%, the
        # allowable size threshold scales proportionally with playback progress,
        # e.g., at 12% playback the threshold is 12% of the original size.
        # This avoids firing at 12% progress while still judging against the
        # stale 10% size threshold.
        if [[ "$video_duration" -gt 0 && "$original_size_bytes" -gt 0 && \
              "$elapsed_us" =~ ^[0-9]+$ ]]; then
            local tenth_time_us=$((video_duration * 1000000 / 10))
            if [[ "$elapsed_us" -ge "$tenth_time_us" && \
                  "$total_size" =~ ^[0-9]+$ ]]; then
                local pct=$((elapsed_us * 100 / 1000000 / video_duration))
                local size_threshold=$((original_size_bytes * pct / 100))
                # Avoid integer-rounding to zero on very small files; require at least one byte.
                [[ $size_threshold -lt 1 ]] && size_threshold=1
                if [[ "$total_size" -ge "$size_threshold" ]]; then
                    local current_mb=$((total_size / 1024 / 1024))
                    local threshold_mb=$((size_threshold / 1024 / 1024))
                    write_log "$job $video_name WARN: Reached ${pct}% playback (${elapsed_sec}s) with output ${current_mb}MB >= proportional threshold (${threshold_mb}MB), aborting transcode early"
                    echo "early-abort-10pct" > "$monitor_flag"
                    # SIGTERM asks ffmpeg to shut down cleanly; allow a short grace
                    # period, then force-kill if it is still alive.
                    kill "$ffmpeg_pid" 2>/dev/null || true
                    local grace=0
                    while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $grace -lt 5 ]]; do
                        sleep 1
                        grace=$((grace + 1))
                    done
                    kill -9 "$ffmpeg_pid" 2>/dev/null || true
                    abort_early_cleanup "$output_path" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid"
                    return 2
                fi
            fi
        fi

        if [[ "$total_size" =~ ^[0-9]+$ && "$total_size" -gt "$original_size_bytes" ]]; then
            local current_mb=$((total_size / 1024 / 1024))
            local original_mb=$((original_size_bytes / 1024 / 1024))
            # Only kill if it's significantly larger (e.g., > 5 MB larger)
            if (( current_mb > original_mb + 5 )); then
                write_log "$job $video_name WARN: Output ($current_mb MB) significantly exceeds original ($original_mb MB), killing transcode"
                echo "output-too-large" > "$monitor_flag"
                kill -9 "$ffmpeg_pid" 2>/dev/null || true
                abort_early_cleanup "$output_path" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid"
                return 2
            fi
        fi

        now=$(date +%s)
        if [[ $((now - last_log_time)) -ge 30 ]]; then
            local pct="?"
            if [[ -n "$elapsed_us" && "$video_duration" -gt 0 ]]; then
                pct=$(( elapsed_us * 100 / 1000000 / video_duration ))
            fi
            write_log "$job $video_name progress: ${pct}% elapsed=${elapsed_sec:-?}s frame=${frame:-?} fps=${fps:-?} speed=${speed:-?}"
            last_log_time=$(date +%s)
        fi
    done
    rm -f "$progress_file" "$monitor_flag" 2>/dev/null || true
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

    if [[ ! -f "$output_path" ]]; then
        write_log "$job $video_name ERROR - output not found"
        write_skip "$video_name" "output-not-found"
        cleanup_job_folder "$output_path"
        return 1
    fi
    local video_new_size_mb
    video_new_size_mb=$(stat --format=%s "$output_path" 2>/dev/null)
    video_new_size_mb=$((video_new_size_mb / 1024 / 1024))
    if [[ $video_new_size_mb -eq 0 ]]; then
        write_log "$job $video_name ERROR, zero file size (${video_new_size_mb}MB), File NOT moved"
        write_skip "$video_name" "zero-size"
        cleanup_job_folder "$output_path"
        return 1
    fi
    local new_media_info_json
    new_media_info_json=$(get_media_info "$output_path")
    local video_new_videocodec video_new_audiocodec video_new_channels video_new_width video_new_duration_float video_new_duration_tag video_new_audio_count
    local _new_meta
    _new_meta=$(echo "$new_media_info_json" | jq -r '
        [
            ([.streams[] | select(.codec_type=="video") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .channels] | first) // 0,
            ([.streams[] | select(.codec_type=="video") | .width] | first) // 0,
            (.format.duration) // 0,
            ([.streams[] | select(.codec_type=="video") | .tags.DURATION] | first) // "null",
            ([.streams[] | select(.codec_type=="audio")] | length)
        ] | map(tostring) | join(" ")
    ')
    read -r video_new_videocodec video_new_audiocodec video_new_channels video_new_width video_new_duration_float video_new_duration_tag video_new_audio_count <<< "$_new_meta"
    local video_new_duration=${video_new_duration_float%.*}
    if [[ "$video_new_duration_tag" != "null" && "$video_new_duration_tag" =~ ^([0-9]+):([0-9]+):([0-9]+) ]]; then
        local new_tag_duration=$(( 10#${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[2]}*60 + 10#${BASH_REMATCH[3]} ))
        [[ $new_tag_duration -gt 0 ]] && video_new_duration=$new_tag_duration
    fi
    if [[ -z "$video_new_duration" || "$video_new_duration" -eq 0 || $video_new_duration -lt $((video_duration - DURATION_TOLERANCE)) || $video_new_duration -gt $((video_duration + DURATION_TOLERANCE)) ]]; then
        write_log "$job $video_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved"
        write_skip "$video_name" "duration-mismatch"
        cleanup_job_folder "$output_path"
        return 1
    fi
    if [[ -z "$video_new_videocodec" || "$video_new_videocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no video stream detected, File NOT moved"
        write_skip "$video_name" "no-video-stream"
        cleanup_job_folder "$output_path"
        return 1
    fi
    if [[ -z "$video_new_audiocodec" || "$video_new_audiocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no audio stream detected, File NOT moved"
        write_skip "$video_name" "no-audio-stream"
        cleanup_job_folder "$output_path"
        return 1
    fi
    local diff_mb diff_percent
    diff_mb=$((video_size_mb - video_new_size_mb))
    if [[ $video_size_mb -eq 0 ]]; then
        diff_percent=0
    else
        diff_percent=$(((video_size_mb - video_new_size_mb) * 100 / video_size_mb))
    fi
    # Relaxed check: only fail if it's way too big or way too small
    local max_size_limit=$((video_size_mb + 500))
    if [[ $video_new_size_mb -gt $max_size_limit ]]; then
        write_log "$job $video_name ERROR, output significantly larger than original (${video_size_mb}MB -> ${video_new_size_mb}MB), File NOT moved"
        write_skip "$video_name" "output-too-large"
        cleanup_job_folder "$output_path"
        return 1
    fi
    if [[ $diff_percent -lt $FFMPEG_MIN_DIFF ]]; then
        write_log "$job $video_name ERROR, min difference too small (${diff_percent}% < ${FFMPEG_MIN_DIFF}%) ${video_size_mb}MB -> ${video_new_size_mb}MB, File NOT moved"
        write_skip "$video_name" "below-min-reduction"
        cleanup_job_folder "$output_path"
        return 1
    fi
    if [[ $diff_percent -gt $FFMPEG_MAX_DIFF ]]; then
        write_log "$job $video_name ERROR, max too high (${diff_percent}% > ${FFMPEG_MAX_DIFF}%) ${video_size_mb}MB -> ${video_new_size_mb}MB, File NOT moved"
        write_skip "$video_name" "above-max-reduction"
        cleanup_job_folder "$output_path"
        return 1
    fi
    local end_time
    end_time=$(date +%s)
    local time_taken=$((end_time - start_time))
    local time_mins=$((time_taken / MINUTES_TO_SECONDS))
    local time_secs=$((time_taken % MINUTES_TO_SECONDS))
    local total_time_formatted="${time_mins}:${time_secs}"
    local gb_per_minute=0
    if [[ $time_taken -gt 0 ]]; then
        gb_per_minute=$(awk "BEGIN {printf \"%.2f\", $video_size_mb/1024/($time_taken/$MINUTES_TO_SECONDS)}")
    fi
    if [[ $MOVE_FILE -eq 0 ]]; then
        write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
        write_log "$job $video_name SUCCESS, move file disabled, File NOT moved"
    else
        write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
        write_log "$job $video_name SUCCESS, moving file..."
        sleep $SLEEP_BEFORE_MOVE
        # Copy synchronously, then clean up.  A background cp + immediate rm
        # creates a race: if cp hasn't opened the file before rm removes it,
        # cp fails with "cannot stat".  Synchronous copy is reliable.
        cp "$output_path" "$video_path"
        rm -f "$output_path"
        write_skip "$video_name" "transcoded"
        cleanup_job_folder "$output_path"
        sleep $SLEEP_AFTER_MOVE
    fi
    return 0
}

# ============================================================================
# MAIN EXECUTION - INITIALIZATION & CONFIGURATION LOADING
# ============================================================================
check_dependencies
load_config "${1:-./transcode-config.json}"
SKIP_FILE=${CONFIG_GLOBAL["skip_file"]:-"./skip.csv"}
FFMPEG_VAAPI_DEVICE=${CONFIG_GLOBAL["ffmpeg_vaapi_device"]:-"/dev/dri/renderD128"}
MIN_THREADS=${CONFIG_GLOBAL["min_threads"]:-1}
MAX_THREADS=${CONFIG_GLOBAL["max_threads"]:-8}
GPU_TARGET_PCT=${CONFIG_GLOBAL["gpu_target_pct"]:-70}
GPU_RAMP_WAIT=${CONFIG_GLOBAL["gpu_ramp_wait"]:-10}
GPU_CHECK_INTERVAL=${CONFIG_GLOBAL["gpu_check_interval"]:-30}
# Consecutive sub-target evaluations required before granting a scale-up. Guards
# against transient VCN dips — e.g. a job finishing its encode while still in its
# file-move phase — being misread as sustained spare capacity.
VCN_SAMPLE_INTERVAL=${CONFIG_GLOBAL["vcn_sample_interval"]:-10}
FFMPEG_INPUT_PARAMS=${CONFIG_GLOBAL["ffmpeg_input_params"]:-""}
FFMPEG_LOGGING=${CONFIG_GLOBAL["ffmpeg_logging"]:-"error"}
FFMPEG_TIMEOUT=${CONFIG_GLOBAL["ffmpeg_timeout"]:-3600}
RESTART_QUEUE=${CONFIG_GLOBAL["restart_queue"]:-720}
DAYS_TO_SECONDS=86400
MINUTES_TO_SECONDS=60
# DURATION_TOLERANCE, FFMPEG_MIN_DIFF, FFMPEG_MAX_DIFF, FFMPEG_NICE_PRIORITY,
# SLEEP_BEFORE_MOVE, SLEEP_AFTER_MOVE are set in load_config from JSON.
SCAN_AT_START=${CONFIG_GLOBAL["scan_at_start"]:-0}
MOVE_FILE=${CONFIG_GLOBAL["move_file"]:-0}
# shm reservation tuning for expected-output sizing (P0 fix)
SHM_RESERVE_SAFETY_PCT=${CONFIG_GLOBAL["shm_reserve_safety_pct"]:-130}
SHM_RESERVE_FLOOR_MB=${CONFIG_GLOBAL["shm_reserve_floor_mb"]:-200}
declare -A CONFIG_BV_MB
declare -A dur_lookup
for cfg in "${CONFIG_NAMES[@]}"; do
    CONFIG_BV_MB["$cfg"]=$(parse_bv "${CONFIG_FFMPEG_PARAMS[$cfg]}")
done

initialize_output_folder
show_state

# ============================================================================
# MAIN EXECUTION - MEDIA SCANNING & PREPARATION
# ============================================================================
SCAN_RESULTS="./scan_results.csv"
SCAN_RESULTS_TMP="./scan_results.tmp"
need_scan=0
if [[ $SCAN_AT_START -eq 1 ]]; then
    need_scan=1
elif [[ ! -f "$SCAN_RESULTS" ]]; then
    need_scan=1
fi
if [[ $need_scan -eq 1 ]]; then
    # Run scans for all configurations
    for config_name in "${CONFIG_NAMES[@]}"; do
        run_media_scan "$config_name"
    done
    # Merge the results and sort by size (largest first)
    merge_scan_results "$SCAN_RESULTS"
elif [[ -f "$SCAN_RESULTS" ]] && [[ $(wc -l <"$SCAN_RESULTS") -gt 0 ]]; then
    # Only run scans in background if scan_results.csv exists and has at least 1 line
    (for config_name in "${CONFIG_NAMES[@]}"; do
        run_media_scan "$config_name"
    done
    merge_scan_results "$SCAN_RESULTS_TMP" && mv -f "$SCAN_RESULTS_TMP" "$SCAN_RESULTS") &
else
    # Force foreground scan if no results
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
declare -A skip_lookup
load_skip_file() {
    if [[ -f "$SKIP_FILE" ]]; then
        while IFS=, read -r filename reason; do
            [[ -n "$filename" ]] && skip_lookup["$filename"]="${reason:-unknown}"
        done < "$SKIP_FILE"
    fi
}
load_skip_file
# ============================================================================
# MAIN EXECUTION - PROCESSING LOOP
# ============================================================================
# Concurrency is governed by a live "headroom" grant from the status check
# rather than a ratcheting slot count. Base slots (<= MIN_THREADS) always run;
# extra slots fill only while gpu_has_headroom=1, and a finished task simply
# ends — its slot is not refilled unless headroom is granted again.
gpu_has_headroom=0
video_idx=0
queue_timer=$(date +%s)
last_job_start=0
last_scale_check=0
last_status_log=0
last_vcn_sample=0
vcn_sample_sum=0
vcn_sample_count=0
actual_running=0
last_wait_log=0

while [[ $video_idx -lt ${#videos[@]} ]]; do
    IFS=',' read -r config_name video size <<<"${videos[$video_idx]}"
    if [[ $RESTART_QUEUE -ne 0 ]]; then
        now=$(date +%s)
        elapsed_minutes=$(( (now - queue_timer) / MINUTES_TO_SECONDS ))
        if [[ $elapsed_minutes -gt $RESTART_QUEUE ]]; then
            write_log "[INFO] Restart queue reached. Re-scanning..."
            for cfg_name in "${CONFIG_NAMES[@]}"; do
                run_media_scan "$cfg_name"
            done
            merge_scan_results "$SCAN_RESULTS"
            mapfile -t videos < <(awk -F, '{print $0}' "$SCAN_RESULTS")
            unset skip_lookup; declare -A skip_lookup
            load_skip_file
            video_idx=0
            queue_timer=$(date +%s)
            continue
        fi
    fi
    video_basename="${video##*/}"
    if [[ -n "${skip_lookup[$video_basename]:-}" ]]; then
        video_idx=$((video_idx + 1))
        continue
    fi
    if [[ ! -f "$video" ]]; then
        write_log "[WARN] File no longer exists, skipping: $video_basename"
        video_idx=$((video_idx + 1))
        continue
    fi
    min_size="${CONFIG_MIN_SIZE[$config_name]}"
    video_size_mb=$((size / 1024 / 1024))
    if [[ $video_size_mb -lt $min_size ]]; then
        write_log "HIT VIDEO SIZE LIMIT for config '$config_name' - waiting for running jobs to finish then quitting"
        exit 0
    fi
    video_age=$(get_video_age "$video")
    min_age="${CONFIG_MIN_AGE[$config_name]}"
    if [[ $video_age -lt $min_age ]]; then
        write_log "($((video_idx+1))) $video_basename ($video_size_mb MB, $video_age days old) too new, skipping"
        video_idx=$((video_idx + 1))
        continue
    fi
    _probe=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name:format=duration \
        -of default=noprint_wrappers=1 "$video" 2>/dev/null || true)
    pre_codec=$(echo "$_probe" | awk -F= '/codec_name/{print $2; exit}')
    video_dur=$(echo "$_probe" | awk -F= '/duration/{print $2; exit}')
    video_dur=${video_dur%.*}
    [[ "$video_dur" =~ ^[0-9]+$ ]] || video_dur=0
    dur_lookup["$video"]=$video_dur
    # Reserve shm by EXPECTED output size (duration * target bitrate), not the
    # full source size. The AV1 output is a small fraction of the source, so
    # reserving the source size needlessly caps concurrency and starves the GPU.
    # Falls back to source size when duration is unknown.
    reserve_mb=$(calc_reserve "$config_name" "$video_size_mb" "$video_dur")
    video_codec_skip_list="${CONFIG_SKIP_LIST[$config_name]}"
    IFS=',' read -ra _skiplist <<<"$video_codec_skip_list"
    for _skip in "${_skiplist[@]}"; do
        if [[ "$pre_codec" == "$_skip" ]]; then
            write_log "($((video_idx+1))) $video_basename (${video_size_mb}MB, $pre_codec) in video codec skip list, skipping"
            write_skip "$video_basename" "codec-skip"
            skip_lookup["$video_basename"]="codec-skip"
            video_idx=$((video_idx + 1))
            continue 2
        fi
    done
    
    while true; do
        done_flag=0
        for ((thread = 1; thread <= MAX_THREADS; thread++)); do
            job_name="GPU_$thread"
            pid_var="JOB_PID_$thread"
            start_var="JOB_START_$thread"
            pid="${!pid_var:-}"
            start_time="${!start_var:-}"
            
            if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
                if [[ -n "${start_time:-}" ]] && ((( $(date +%s) - start_time ) > FFMPEG_TIMEOUT * MINUTES_TO_SECONDS)); then
                    echo "[WARN] $job_name timed out, killing PID $pid"
                    kill_tree "$pid"
                    wait "$pid" 2>/dev/null || true
                    unset $pid_var
                    unset $start_var
                fi
            else
                if [[ -n "${pid:-}" ]]; then
                    # Job finished — the slot is now free. It just ends here;
                    # nothing automatically refills it. Reset the ramp timer so
                    # the next scale-up evaluation waits for the GPU to settle:
                    # a finishing job briefly drains VCN, and judging headroom in
                    # that gap would scale up on a false reading.
                    unset $pid_var
                    unset $start_var
                    unset "JOB_SIZE_$thread"
                    last_job_start=$(date +%s)
                fi
                # Scale down by omission: base slots (<= MIN_THREADS) always
                # refill so the GPU stays fed, but an extra slot is only filled
                # while the status check has granted headroom. Under load the
                # grant is withheld, so the freed slot stays empty.
                if [[ $thread -gt $MIN_THREADS && $gpu_has_headroom -ne 1 ]]; then
                    continue
                fi
                
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

                # If other jobs are holding shm and there isn't room, wait.
                if [[ $reserved_mb -gt 0 && $effective_free -lt $reserve_mb ]]; then
                    now=$(date +%s)
                    if [[ $((now - last_wait_log)) -ge $GPU_CHECK_INTERVAL ]]; then
                        echo "[WAIT] /dev/shm ${effective_free}MB available, need ${reserve_mb}MB for $video_basename — waiting for space"
                        last_wait_log=$now
                    fi
                    break
                fi

                # Room available (or this is the only running job): dispatch the
                # current video into this free slot.
                run_job_transcode "$config_name" "$video" "[T${thread}]" "$size" &
                new_pid=$!
                declare $pid_var=$new_pid
                declare $start_var="$(date +%s)"
                declare "JOB_SIZE_$thread=$reserve_mb"
                last_job_start=$(date +%s)
                # Consume the headroom grant; the next scale-up must be
                # re-confirmed by the status check after the ramp wait.
                gpu_has_headroom=0
                done_flag=1
                break
            fi
        done

        if [[ $done_flag -eq 1 ]]; then
            break
        fi
        sleep 0.1
        now=$(date +%s)
        if [[ $((now - last_vcn_sample)) -ge $VCN_SAMPLE_INTERVAL ]]; then
            vcn_sample_sum=$((vcn_sample_sum + $(get_vcn_utilization)))
            vcn_sample_count=$((vcn_sample_count + 1))
            last_vcn_sample=$now
        fi
        if [[ $((now - last_scale_check)) -ge $GPU_CHECK_INTERVAL ]] && \
           [[ $((now - last_job_start)) -ge $GPU_RAMP_WAIT ]]; then
            # Evaluate once per interval so vcn_pct is the average of a full
            # window of samples, not a single noisy instantaneous reading.
            # A transient dip must not flip the headroom grant under load.
            last_scale_check=$now
            if [[ $vcn_sample_count -gt 0 ]]; then
                vcn_pct=$((vcn_sample_sum / vcn_sample_count))
            else
                vcn_pct=$(get_vcn_utilization)
            fi
            # Reset the sample window so vcn_pct reflects only the most
            # recent interval, not a diluted lifetime average.
            vcn_sample_sum=0
            vcn_sample_count=0
            shm_free_mb=$(df -m /dev/shm | awk 'NR==2 {print $4}')
            reserved_mb=0
            actual_running=0
            for ((t = 1; t <= MAX_THREADS; t++)); do
                t_pid_var="JOB_PID_$t"
                t_pid="${!t_pid_var:-}"
                if [[ -n "$t_pid" ]] && kill -0 "$t_pid" 2>/dev/null; then
                    actual_running=$((actual_running + 1))
                    t_size_var="JOB_SIZE_$t"
                    reserved_mb=$((reserved_mb + ${!t_size_var:-0}))
                fi
            done
            effective_free=$((shm_free_mb - reserved_mb))
            if [[ $actual_running -eq 0 ]]; then
                # Nothing running — the base slot starts regardless of any
                # grant, so there is no extra-slot scale-up to consider.
                gpu_has_headroom=0
                scale_action="idle — starting base task"
            elif [[ $vcn_pct -lt $GPU_TARGET_PCT ]]; then
                if [[ $actual_running -ge $MAX_THREADS ]]; then
                    gpu_has_headroom=0
                    scale_action="at max threads (${MAX_THREADS}/${MAX_THREADS})"
                elif [[ $effective_free -lt $reserve_mb ]]; then
                    # GPU has headroom but shm is full — adding a task won't
                    # help, the constraint is memory not the GPU.
                    gpu_has_headroom=0
                    scale_action="waiting for shm"
                else
                    gpu_has_headroom=1
                    scale_action="headroom — scaling up ($((actual_running+1))/${MAX_THREADS})"
                fi
            else
                # GPU at load — withhold the grant.
                # Finished tasks end and their slots are left empty, so
                # concurrency scales down.
                gpu_has_headroom=0
                scale_action="GPU at load"
            fi
            if [[ $((now - last_status_log)) -ge $GPU_CHECK_INTERVAL ]]; then
                shm_display=$((effective_free < 0 ? 0 : effective_free))
                write_log "[STATUS] VCN=${vcn_pct}% threads=${actual_running}/${MAX_THREADS} shm=${shm_display}MB available — ${scale_action}"
                last_status_log=$now
            fi
        fi
    done
    video_idx=$((video_idx + 1))
done
# ============================================================================
# CLEANUP AND EXIT
# ============================================================================
write_log "Queue complete, waiting for running jobs to finish then quitting"
for ((thread = 1; thread <= MAX_THREADS; thread++)); do
    pid_var="JOB_PID_$thread"
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
    fi
done
write_log "Finished processing"
exit 0
