#!/usr/bin/env bash
# media.sh – shared media-info extraction and duration parsing

# Extracts standard media metadata from ffprobe JSON.
# Returns a space-separated string:
#   video_codec audio_codec audio_channels width duration_float duration_tag audio_stream_count
# All fields default to "null"/0 when the stream/format field is missing.
get_media_info_json() {
    local video_path="$1"
    ffprobe -v quiet -print_format json -show_streams -show_format "$video_path"
}

# Parses a space-separated metadata blob (from get_media_meta) into named variables.
# Usage: parse_media_meta "$meta" video_codec audio_codec audio_channels video_width video_duration_float video_duration_tag audio_stream_count
parse_media_meta() {
    local meta="$1"
    local c vcodec acodec achannels vwidth vdur_float vdur_tag astream_count
    vcodec=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="video") | .codec_name] | first) // "null"')
    acodec=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="audio") | .codec_name] | first) // "null"')
    achannels=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="audio") | .channels] | first) // 0')
    vwidth=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="video") | .width] | first) // 0')
    vdur_float=$(echo "$meta" | jq -r '(.format.duration) // 0')
    vdur_tag=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="video") | .tags.DURATION] | first) // "null"')
    astream_count=$(echo "$meta" | jq -r '([.streams[] | select(.codec_type=="audio")] | length)')

    # Write results into the caller's nominated variables (by reference, via eval).
    # We use printf -v for indirect assignment where supported.
    printf -v "$2" '%s' "$vcodec"
    printf -v "$3" '%s' "$acodec"
    printf -v "$4" '%s' "$achannels"
    printf -v "$5" '%s' "$vwidth"
    printf -v "$6" '%s' "$vdur_float"
    printf -v "$7" '%s' "$vdur_tag"
    printf -v "$8" '%s' "$astream_count"
}

# Parse a HH:MM:SS or HH:MM:SS.sss duration tag into integer seconds.
# If the tag is "null" or unparseable, leaves the existing value untouched.
parse_duration_from_tag() {
    local duration_tag="$1"
    local -n _out_duration=$2   # nameref to the caller's duration variable
    if [[ "$duration_tag" != "null" && "$duration_tag" =~ ^([0-9]+):([0-9]+):([0-9]+) ]]; then
        local tag_duration=$(( 10#${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[2]}*60 + 10#${BASH_REMATCH[3]} ))
        [[ $tag_duration -gt 0 ]] && _out_duration=$tag_duration
    fi
}

# Compute size-difference percentage (always integer, rounded toward saving).
# Returns: diff_percent = (old - new) * 100 / old
compute_diff_percent() {
    local old_size="$1"
    local new_size="$2"
    local -n _out=$3
    if [[ $old_size -eq 0 ]]; then
        _out=0
    else
        _out=$(((old_size - new_size) * 100 / old_size))
    fi
}
