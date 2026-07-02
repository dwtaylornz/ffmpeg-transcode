#!/usr/bin/env bash
# config.sh – dependency checks, VCN monitoring, and JSON config loading
# Source this file from the main transcode script.

check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required but not installed. Please install jq to continue."
        exit 1
    fi
    if ! command -v ffmpeg &> /dev/null; then
        echo "ERROR: ffmpeg is required but not installed. Please install ffmpeg to continue."
        exit 1
    fi
    if ! command -v ffprobe &> /dev/null; then
        echo "ERROR: ffprobe is required but not installed. Please install ffprobe to continue."
        exit 1
    fi
}

# Cache the VCN busy file path at startup to avoid re-resolving each sample.
_vcn_busy_path=""
_resolve_vcn_path() {
    if [[ -n "$_vcn_busy_path" ]]; then
        return 0
    fi
    local render_dev
    render_dev=$(basename "${FFMPEG_VAAPI_DEVICE:-/dev/dri/renderD128}")
    local device_path
    device_path=$(readlink -f "/sys/class/drm/${render_dev}/device" 2>/dev/null)
    local busy_file="${device_path}/vcn_busy_percent"
    if [[ -r "$busy_file" ]]; then
        _vcn_busy_path="$busy_file"
        return 0
    fi
    for f in /sys/class/drm/card*/device/vcn_busy_percent; do
        if [[ -r "$f" ]]; then
            _vcn_busy_path="$f"
            return 0
        fi
    done
    _vcn_busy_path=""
    return 1
}

get_vcn_utilization() {
    _resolve_vcn_path || { echo 0; return; }
    cat "$_vcn_busy_path" 2>/dev/null || echo 0
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
    FFMPEG_MIN_DIFF=${CONFIG_GLOBAL["ffmpeg_min_diff"]:-10}
    FFMPEG_MAX_DIFF=${CONFIG_GLOBAL["ffmpeg_max_diff"]:-95}
    FFMPEG_NICE_PRIORITY=${CONFIG_GLOBAL["ffmpeg_nice_priority"]:--20}
    DURATION_TOLERANCE=${CONFIG_GLOBAL["duration_tolerance"]:-30}
    SLEEP_BEFORE_MOVE=${CONFIG_GLOBAL["sleep_before_move"]:-2}
    SLEEP_AFTER_MOVE=${CONFIG_GLOBAL["sleep_after_move"]:-2}
}
