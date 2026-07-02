#!/usr/bin/env bash
# logging.sh – consistent logging, skip-file management, and state display

# Color semantics used by write_log():
#   red    = ERROR
#   orange = WARN
#   yellow = SUCCESS
#   green  = INFO
write_log() {
    local log_string="$1"
    local log_file="./transcode.log"
    local stamp
    stamp="$(date '+%y/%m/%d %H:%M:%S')"
    local log_message="$stamp $log_string"
    if [[ "$log_message" == *"ERROR"* ]]; then
        echo -e "${COLOR_RED}$log_message${COLOR_RESET}"
    elif [[ "$log_message" == *"WARN"* ]]; then
        echo -e "${COLOR_ORANGE}$log_message${COLOR_RESET}"
    elif [[ "$log_message" == *"SUCCESS"* ]]; then
        echo -e "${COLOR_YELLOW}$log_message${COLOR_RESET}"
    elif [[ "$log_message" == *"INFO"* ]]; then
        echo -e "${COLOR_GREEN}$log_message${COLOR_RESET}"
    else
        echo "$log_message"
    fi
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

write_skip_error() {
    write_skip "$1" "$2"
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
    echo "  Previously errored files:  $skippederror_count"
    echo "  Total files to skip:       $skiptotal_count"
    echo "  Global Settings - Threads: ${MIN_THREADS}-${MAX_THREADS} (VCN target: ${GPU_TARGET_PCT}%), Timeout: $FFMPEG_TIMEOUT, Restart Queue: $RESTART_QUEUE"
    echo ""
    echo "  Loaded Configurations:"
    local config_name
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
