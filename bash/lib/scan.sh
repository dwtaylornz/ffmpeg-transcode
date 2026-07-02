#!/usr/bin/env bash
# scan.sh – media scanning and skip-file management

get_video_age() {
    local video_path="$1"
    local ctime now
    ctime=$(stat -c %Y "$video_path")
    now=$(date +%s)
    echo $(((now - ctime) / DAYS_TO_SECONDS))
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
    local config_name
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

load_skip_file() {
    if [[ -f "$SKIP_FILE" ]]; then
        while IFS=, read -r filename reason; do
            [[ -n "$filename" ]] && skip_lookup["$filename"]="${reason:-unknown}"
        done < "$SKIP_FILE"
    fi
}
