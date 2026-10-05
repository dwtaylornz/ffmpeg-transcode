#!/usr/bin/env bash
#
# FFmpeg Video Transcoding Script
#
set -euo pipefail
# ============================================================================
# CONFIGURATION & ARGUMENTS
# ============================================================================
DRY_RUN=0
DRY_RUN_LIMIT=20
JOB_LIMIT=0
MAX_SIZE_MB=0
AUDIO_ONLY=0
RETRY_FAILED=0
CONFIG_FILE=""
declare -a INPLACE_TEMPS=()

usage() {
    cat <<'EOF'
Usage: transcode.sh [options]

  --config PATH    Configuration file (default ./transcode-config.json)
  -n, --dry-run    Probe each file and print the ffmpeg command that would run,
                   without running ffmpeg, writing skip entries, touching
                   /dev/shm, or modifying any media file.
  --limit N        Process at most N files, then drain running jobs and stop.
                   With --dry-run, preview at most N files instead (default 20).
  --max-size-mb N  Only process files no larger than N MB.  Combined with
                   --limit this gives a fast smoke test on small real files,
                   since the queue is otherwise sorted largest-first.
  --audio-only     Never re-encode video: treat every file as an audio-only
                   remux (video stream copied).  Needs no GPU, so it never
                   competes with the encoders for VCN time — run it instead of
                   the normal queue, not alongside it (one instance at a time).
  --retry-failed   Re-queue files that previously failed (ffmpeg-crash-*),
                   were aborted as size-inefficient, or ended with a
                   duration-mismatch, so they get one pass through the current
                   retry ladder.  A .bak of the skip file is kept.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --config)    CONFIG_FILE="${2:-}"; shift 2 ;;
        --config=*)  CONFIG_FILE="${1#*=}"; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --limit)     DRY_RUN_LIMIT="${2:-20}"; JOB_LIMIT="${2:-0}"; shift 2 ;;
        --limit=*)   DRY_RUN_LIMIT="${1#*=}"; JOB_LIMIT="${1#*=}"; shift ;;
        --max-size-mb)   MAX_SIZE_MB="${2:-0}"; shift 2 ;;
        --max-size-mb=*) MAX_SIZE_MB="${1#*=}"; shift ;;
        --audio-only) AUDIO_ONLY=1; shift ;;
        --retry-failed) RETRY_FAILED=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument '${1}'" >&2
            usage >&2
            exit 2
            ;;
    esac
done
if ! [[ "$DRY_RUN_LIMIT" =~ ^[0-9]+$ ]] || [[ "$DRY_RUN_LIMIT" -lt 1 ]]; then
    DRY_RUN_LIMIT=20
fi
if ! [[ "$JOB_LIMIT" =~ ^[0-9]+$ ]]; then
    JOB_LIMIT=0
fi
if ! [[ "$MAX_SIZE_MB" =~ ^[0-9]+$ ]]; then
    MAX_SIZE_MB=0
fi
# A dry run must not append to the live log or delete the shared-memory output
# folder: a real transcode may be running in another terminal.
LOG_TO_FILE=1
if [[ $DRY_RUN -eq 1 ]]; then
    LOG_TO_FILE=0
fi

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
    if [[ "${LOG_TO_FILE:-1}" -eq 1 ]]; then
        echo "$log_message" >>"$log_file"
    fi
}

write_skip() {
    local video_name="$1"
    local reason="${2:-transcoded}"
    local existing="${skip_lookup[$video_name]:-}"
    if [[ "$existing" == "$reason" ]]; then
        return 0
    fi
    # A file that has reached a final state is never rewritten.  But a
    # non-terminal state (audio fixed, video still pending) must be upgradeable:
    # without this, a file processed audio-first and video-later would stay
    # "pending" forever and be re-probed on every run.
    if [[ -n "$existing" ]] && is_terminal_skip_reason "$existing"; then
        return 0
    fi
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        skip_lookup["$video_name"]="$reason"
        return 0
    fi
    printf '%s,%s\n' "$video_name" "$reason" >>"$SKIP_FILE"
    skip_lookup["$video_name"]="$reason"
    return 0
}

initialize_output_folder() {
    local output_path="${CONFIG_GLOBAL["output_path"]:-/dev/shm/ffmpeg-transcode}"
    rm -rf "${output_path:?}"
    mkdir -p "$output_path"
}

cleanup_shm() {
    local shm_path="/dev/shm/ffmpeg-transcode"
    if [[ -d "$shm_path" ]]; then
        rm -rf "$shm_path"
    fi
    return 0
}

# Remove any in-place staging files left behind by audio-only jobs.  Successful
# jobs rename their temp over the source, and failing jobs delete their own temp;
# this is the safety net for signals and for the script dying mid-job.
cleanup_temp_files() {
    local t
    for t in "${INPLACE_TEMPS[@]:-}"; do
        if [[ -n "$t" && -f "$t" ]]; then
            rm -f "$t" 2>/dev/null || true
        fi
    done
    return 0
}

cleanup_on_exit() {
    # A dry run shares /dev/shm and the media tree with whatever real run may be
    # in flight, so it must never clean anything up.
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        return 0
    fi
    cleanup_temp_files
    cleanup_shm
    return 0
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
        unset "JOB_TYPE_$thread" 2>/dev/null || true
    done
    # cleanup_shm is handled by the EXIT trap
    cleanup_temp_files
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
trap cleanup_on_exit EXIT

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
    local cfg="$1" sz_mb="$2" dur="$3" video_action="${4:-encode}"
    # A copy job writes essentially the whole source back out again, so there is
    # no bitrate-based saving to exploit. (Audio-only jobs stage in place and
    # reserve nothing at all; callers skip this function for those.)
    if [[ "$video_action" == "copy" ]]; then
        echo "$sz_mb"
        return
    fi
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

# ============================================================================
# AUDIO POLICY
# ============================================================================

# Resolve an integer duration (seconds) from a media-info JSON, preferring the
# video stream's DURATION tag when the container does not report one (Matroska
# files written by some muxers have no format.duration).
resolve_duration() {
    local json="$1"
    local d tag
    # 1) The video stream's mkvmerge DURATION tag ("HH:MM:SS.mmm") is the most
    #    accurate cheap signal: it is the stream's own encoded span.  The
    #    CONTAINER duration can exceed it by trailing audio/subtitle padding,
    #    which is the documented cause of false "incorrect duration" failures.
    tag=$(printf '%s' "$json" | jq -r '([.streams[] | select(.codec_type=="video") | .tags.DURATION] | first) // "null"' 2>/dev/null)
    if [[ "$tag" != "null" && "$tag" =~ ^([0-9]+):([0-9]+):([0-9]+) ]]; then
        d=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
    else
        # 2) The video stream's own duration field (present on mp4 / other muxers).
        d=$(printf '%s' "$json" | jq -r '[.streams[] | select(.codec_type=="video") | (.duration // 0)] | first | tostring' 2>/dev/null)
        d=${d%%.*}
        [[ "$d" =~ ^[0-9]+$ ]] || d=0
        # 3) Frame count divided by average rate, when both are known.
        if [[ "$d" -le 0 ]]; then
            local nf ar num den
            nf=$(printf '%s' "$json" | jq -r '[.streams[] | select(.codec_type=="video") | (.nb_frames // 0)] | first | tostring' 2>/dev/null)
            ar=$(printf '%s' "$json" | jq -r '[.streams[] | select(.codec_type=="video") | (.avg_frame_rate // "0/0")] | first' 2>/dev/null)
            num=${ar%/*}; den=${ar#*/}
            if [[ "$nf" =~ ^[0-9]+$ && "$num" =~ ^[0-9]+$ && "$den" =~ ^[0-9]+$ && "$den" -gt 0 ]]; then
                d=$(( nf * den / num ))
            fi
        fi
        # 4) Last resort: the container duration.  May pad past the true video
        #    span; the duration check applies a relative floor to absorb that.
        if [[ "$d" -le 0 ]]; then
            d=$(printf '%s' "$json" | jq -r '(.format.duration // 0) | tostring' 2>/dev/null)
            d=${d%%.*}
            [[ "$d" =~ ^[0-9]+$ ]] || d=0
        fi
    fi
    echo "$d"
}

# Pick the one audio stream to keep and summarise the audio situation.
# Selection order: first stream in a preferred language -> stream flagged
# default -> first stream.  Language deliberately outranks the default flag:
# measured on this library, multi-language WEB-DL releases routinely flag a
# non-English track as default (Black Mirror S07E03 flags Ukrainian, Sonic Prime
# S03E07 flags Arabic), so trusting the flag would leave foreign-language-only
# audio.  The index reported is AUDIO-RELATIVE (position within the audio stream
# list), which is what "-map 0:a:N" expects.
#
# Emits a pipe-delimited record:
#   vcodec|acodec|channels|bitrate|duration|audio_rel_idx|audio_count|language|channel_layout
parse_media_meta() {
    local json="$1"
    printf '%s' "$json" | jq -r --arg langs "$AUDIO_PREFERRED_LANGS" '
        ($langs | split(",") | map(select(length > 0) | ascii_downcase)) as $L |
        def lang_match($l):
            ($l | ascii_downcase) as $t |
            ([$L[] | select(. as $p | $t == $p or ($t | startswith($p)))] | length) > 0;
        ([.streams[] | select(.codec_type=="video")] | first) as $v |
        ([.streams[] | select(.codec_type=="audio")]) as $a |
        ($a | to_entries
            | map(select(lang_match(.value.tags.language // "")))
            | first) as $pref |
        ($a | to_entries | map(select(.value.disposition.default == 1)) | first) as $def |
        ($a | to_entries | first) as $first |
        ($pref // $def // $first) as $c |
        [
            ($v.codec_name // "null"),
            ($c.value.codec_name // "null"),
            ($c.value.channels // 0),
            ($c.value.bit_rate // 0),
            (($c.value.tags.DURATION // "null")),
            ($c.key // -1),
            ($a | length),
            ($c.value.tags.language // ""),
            ($c.value.channel_layout // ""),
            ($v.width // 0),
            ($v.height // 0),
            ($v.avg_frame_rate // "0/1")
        ] | map(tostring) | join("|")
    ' 2>/dev/null
}

# Decide what to do with the audio of a file.  Echoes one of:
#   none   - already compliant, nothing worth doing
#   prune  - keep only the chosen track, copy it (no re-encode)
#   encode - keep only the chosen track and re-encode it to the target codec
decide_audio_action() {
    local acodec="$1" ach="$2" abr="$3" acount="$4" max_tracks="${5:-$AUDIO_MAX_TRACKS}"
    local need=0 c

    if [[ -z "$acodec" || "$acodec" == "null" ]]; then
        echo "encode"
        return 0
    fi

    # Lossless / high-bitrate codecs always get re-encoded.
    IFS=',' read -ra _always <<<"$AUDIO_ALWAYS_RECODE"
    for c in "${_always[@]}"; do
        [[ -z "$c" ]] && continue
        # Unquoted right-hand side: a config value like "pcm_*" acts as a glob.
        # shellcheck disable=SC2053
        if [[ "$acodec" == $c ]]; then
            need=1
            break
        fi
    done

    # More channels than the target layout.
    if [[ "$ach" =~ ^[0-9]+$ ]] && (( ach > AUDIO_CHANNELS )); then
        need=1
    fi

    # Bitrate well above what the target codec needs for this channel count.
    if [[ "$abr" =~ ^[0-9]+$ ]] && (( abr > 0 && abr > AUDIO_MIN_BITRATE_KBPS * 1000 )); then
        need=1
    fi

    if (( need == 1 )); then
        echo "encode"
        return 0
    fi
    if [[ "$acount" =~ ^[0-9]+$ ]] && (( acount > max_tracks )); then
        echo "prune"
        return 0
    fi
    echo "none"
}

# Rebuild an ffmpeg parameter string without its audio output options, so the
# script's own audio arguments are the only ones in play.  Understands the
# single-quoted values used in transcode-config.json (e.g. -vf 'format=nv12,...')
# and re-quotes each surviving token so the string still survives the eval layer
# in run_job_transcode.
strip_audio_opts() {
    local params="$1"
    local -a toks=()
    if ! eval "toks=($params)" 2>/dev/null; then
        printf '%s' "$params"
        return 0
    fi
    local -a keep=()
    local i=0 n=${#toks[@]} t
    while (( i < n )); do
        t="${toks[$i]}"
        case "$t" in
            -c:a|-codec:a|-acodec|-ac|-b:a|-ar|-af|-filter:a|-sample_fmt)
                i=$(( i + 2 ))
                continue
                ;;
            -c:a:*|-codec:a:*|-b:a:*|-ac:*|-ar:*|-filter:a:*)
                i=$(( i + 1 ))
                continue
                ;;
        esac
        keep+=("$t")
        i=$(( i + 1 ))
    done
    local out="" tok
    for tok in "${keep[@]:-}"; do
        [[ -z "$tok" ]] && continue
        out+=" $(printf '%q' "$tok")"
    done
    printf '%s' "${out# }"
}

# Remove hardware-accelerator input options.  Two modes, because "no hardware"
# means different things on the remux path and on the retry ladder:
#
#   strip_hwaccel_opts "<params>"          drop EVERY hardware option, including
#                                          the device initialisation.  An
#                                          audio-only remux copies the video
#                                          stream, so it never needs a decode
#                                          device and must not fail (or contend
#                                          for the GPU) when one is unavailable.
#
#   strip_hwaccel_opts "<params>" decode   drop only the DECODE-side options and
#                                          keep -vaapi_device / -init_hw_device /
#                                          -filter_hw_device.  The ladder's
#                                          software-decode rung still encodes with
#                                          av1_vaapi and its output chain still ends
#                                          in hwupload; both need the device
#                                          reference that -vaapi_device provides.
#                                          Dropping it fails with "A hardware
#                                          device reference is required to upload
#                                          frames to", which is precisely the
#                                          fault rung 3 exists to work around.
strip_hwaccel_opts() {
    local params="$1" mode="${2:-all}"
    local -a toks=()
    if ! eval "toks=($params)" 2>/dev/null; then
        printf '%s' "$params"
        return 0
    fi
    local -a keep=()
    local i=0 n=${#toks[@]} t
    while (( i < n )); do
        t="${toks[$i]}"
        case "$t" in
            -vaapi_device|-init_hw_device|-filter_hw_device)
                if [[ "$mode" == "decode" ]]; then
                    keep+=("$t")
                    i=$(( i + 1 ))
                    continue
                fi
                i=$(( i + 2 ))
                continue
                ;;
            -hwaccel|-hwaccel_device|-hwaccel_output_format)
                i=$(( i + 2 ))
                continue
                ;;
            -vaapi_device:*|-init_hw_device:*|-filter_hw_device:*)
                [[ "$mode" == "decode" ]] && keep+=("$t")
                i=$(( i + 1 ))
                continue
                ;;
            -hwaccel:*|-hwaccel_device:*|-hwaccel_output_format:*)
                i=$(( i + 1 ))
                continue
                ;;
        esac
        keep+=("$t")
        i=$(( i + 1 ))
    done
    local out="" tok
    for tok in "${keep[@]:-}"; do
        [[ -z "$tok" ]] && continue
        out+=" $(printf '%q' "$tok")"
    done
    printf '%s' "${out# }"
}

# Prefix the video filter chain in an ffmpeg parameter string, e.g. turning
# "-vf 'format=nv12,hwupload'" into "-vf 'scale=...,pad=...,format=nv12,hwupload'".
# If the string has no video filter, one is added.  Re-quoted so it survives the
# eval layer.
prefix_vf() {
    local params="$1" prefix="$2"
    local -a toks=()
    if ! eval "toks=($params)" 2>/dev/null; then
        printf '%s' "$params"
        return 0
    fi
    local -a out=()
    local i=0 n=${#toks[@]} found=0 t
    while (( i < n )); do
        t="${toks[$i]}"
        case "$t" in
            -vf|-filter:v|-filter)
                out+=("-vf" "${prefix},${toks[$(( i + 1 ))]:-}")
                i=$(( i + 2 ))
                found=1
                continue
                ;;
            -vf:*|-filter:v:*|-filter:*)
                out+=("-vf" "${prefix},${t#*:}")
                i=$(( i + 1 ))
                found=1
                continue
                ;;
        esac
        out+=("$t")
        i=$(( i + 1 ))
    done
    if (( found == 0 )); then
        out+=("-vf" "$prefix")
    fi
    local s="" tok
    for tok in "${out[@]:-}"; do
        [[ -z "$tok" ]] && continue
        s+=" $(printf '%q' "$tok")"
    done
    printf '%s' "${s# }"
}

# Build the ffmpeg command line for one job.  Echoed (not executed) so the
# dry-run can print exactly what would happen.
#
# `attempt` selects the fallback rung of the retry ladder (see run_job_transcode):
#   1 - as configured
#   2 - normalise every frame onto a fixed canvas and stop ffmpeg from trying to
#       rebuild the filter graph when the source changes parameters mid-stream
#   3 - rung 2 plus software decode (the VAAPI device is kept: hwupload and the
#       av1_vaapi encoder still need it)
# Does this container carry the primary audio codec?
#
# Opus is the case that forces a per-file decision rather than a global one:
# ffmpeg will happily write Opus into MP4 -- producing a file that probes
# perfectly and that no player will actually read -- and refuses MOV outright
# with "opus only supported in MP4".  So anything outside audio_containers gets
# the fallback codec instead.
# Extension the transcoded OUTPUT file will be written under.  ffmpeg picks the
# muxer from the output filename's extension, and several muxers refuse the
# streams this pipeline produces - e.g. WebM only accepts VP8/VP9/AV1 video,
# Vorbis/Opus audio and WebVTT subtitles (a copied non-WebVTT sub makes every
# attempt fail with "Could not write header", and the observed ffmpeg build even
# segfaults on it, exit 139), and the AVI/ASF muxers carry neither AV1 nor Opus.
# mkv and mp4 are known-good for av1 + opus/ac3 + arbitrary subtitles; anything
# else is remapped to mkv, which is what actually changes the muxer.
output_container_ext() {
    local ext
    ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mkv|mp4) printf '%s' "$ext" ;;
        *)       printf 'mkv' ;;
    esac
}

# Whether the container the file ends up in carries the primary audio codec.
# Optional second argument is the job's video_action: "copy" (audio-only remux)
# keeps the source's own extension in place, so it checks that; the video-encode
# path checks the extension the output is *remapped* to, so an .avi source is a
# matroska output and gets opus, not the ac3 fallback.
container_supports_primary_audio() {
    local path="$1" action="${2:-}"
    local ext
    if [[ "$action" == "copy" ]]; then
        ext=$(printf '%s' "${path##*.}" | tr '[:upper:]' '[:lower:]')
    else
        ext=$(output_container_ext "$path")
    fi
    [[ ",${AUDIO_CONTAINERS}," == *",${ext},"* ]]
}

# The stream codec name (as ffprobe reports it) that this file will end up with.
audio_codec_for() {
    if container_supports_primary_audio "$1" "${2:-}"; then
        printf '%s' "$AUDIO_CODEC"
    else
        printf '%s' "$AUDIO_FALLBACK_CODEC"
    fi
}

# The libavcodec encoder to pass to -c:a for this file.
audio_encoder_for() {
    if container_supports_primary_audio "$1" "${2:-}"; then
        printf '%s' "$AUDIO_ENCODER"
    else
        # The fallback codec doubles as its own encoder name (ac3 -> ac3).
        printf '%s' "$AUDIO_FALLBACK_CODEC"
    fi
}

build_ffmpeg_cmd() {
    local config_name="$1" video_path="$2" video_action="$3" audio_action="$4"
    local audio_rel="$5" output_path="$6" progress_file="$7" ffmpeg_err_file="$8"
    local attempt="${9:-1}" canvas="${10:-}" audio_style="${11:-fold}"
    local ffmpeg_output_params="${CONFIG_FFMPEG_PARAMS[$config_name]}"

    local video_params audio_map audio_args input_params
    # Pick the codec this container can actually carry (see the helpers above).
    # The audio decision follows the OUTPUT container: a video-encode job on an
    # .avi source is remapped to matroska, so it gets opus, not the ac3 fallback.
    local audio_encoder audio_bitrate
    audio_encoder=$(audio_encoder_for "$video_path" "$video_action")
    if container_supports_primary_audio "$video_path" "$video_action"; then
        audio_bitrate="${CONFIG_AUDIO_BITRATE[$config_name]:-$AUDIO_BITRATE}"
    else
        audio_bitrate="$AUDIO_FALLBACK_BITRATE"
    fi
    input_params="$FFMPEG_INPUT_PARAMS"
    if [[ "$video_action" == "copy" ]]; then
        # Audio-only remux: never touch the video, never inherit the hardware
        # upload filter chain, and do not require a decode device.
        video_params="-c:v copy -max_muxing_queue_size ${MUX_QUEUE_SIZE:-9999}"
        input_params=$(strip_hwaccel_opts "$input_params")
    else
        video_params=$(strip_audio_opts "$ffmpeg_output_params")
        if [[ "$attempt" -ge 2 && -n "$canvas" ]]; then
            local w="${canvas%x*}" h="${canvas#*x}"
            # force_original_aspect_ratio + pad keeps the aspect ratio while
            # making every output frame the same size, so the rest of the chain
            # (and the hardware encoder) never sees the stream change.
            video_params=$(prefix_vf "$video_params" \
                "scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2")
            # Without this, ffmpeg still tries to rebuild the graph on a
            # mid-stream parameter change and fails on hardware encoders.
            input_params="-reinit_filter 0 $input_params"
        fi
        if [[ "$attempt" -ge 3 ]]; then
            # Decode-side options only.  Stripping -vaapi_device here too would
            # leave hwupload with no device to upload to, so the software-decode
            # rung would fail for a brand new reason on every attempt.
            input_params=$(strip_hwaccel_opts "$input_params" decode)
        fi
        if [[ "$attempt" -ge 4 ]]; then
            # Broken / non-monotonic source timestamps: ignore the container's
            # DTS and derive them from PTS.  This is the documented remedy for
            # "non monotonically increasing dts", and it can stop an encoder
            # from terminating early on a disordered stream.
            input_params="-fflags +igndts+genpts $input_params"
        fi
    fi

    case "$audio_action" in
        encode)
            audio_map="-map 0:a:${audio_rel}"
            audio_args="-c:a $audio_encoder -ac $AUDIO_CHANNELS -ar $AUDIO_SAMPLE_RATE"
            if [[ "${AUDIO_VBR:-0}" =~ ^[1-5]$ && "$audio_encoder" == "libfdk_aac" ]]; then
                # libfdk_aac VBR: the rate is content-driven, so -b:a is
                # deliberately omitted rather than passed as well.
                #
                # -vbr is a libfdk-only option, hence the encoder check: passing
                # it to ac3 or to the native aac encoder fails the job outright,
                # so a stray audio_vbr with a non-libfdk encoder degrades to CBR
                # instead of blacklisting every file it touches.
                audio_args+=" -vbr $AUDIO_VBR"
            else
                audio_args+=" -b:a $audio_bitrate"
            fi
            if [[ "$audio_encoder" == "libfdk_aac" || "$audio_encoder" == "aac" ]]; then
                # Pin AAC-LC; left to itself libfdk can pick a profile that Plex
                # clients negotiate less predictably.
                audio_args+=" -profile:a aac_low"
            fi
            if [[ "${AUDIO_LFE_FOLD:-0}" -eq 1 ]]; then
                # Fold every centre/surround/LFE channel into the stereo pair so
                # the subwoofer still receives what a plain downmix discards.
                #
                # One expression covers every input layout: the pan filter treats
                # input channels that are absent as silent, so stereo passes
                # through, 3.0 folds only FC and 2.1 folds only LFE, with no
                # double counting.
                #
                # EVERY channel named here is load-bearing.  An earlier version
                # named only FL/FR/FC/BL/BR/LFE, which silently DISCARDED the side
                # surrounds: '5.1(side)' is FL+FR+FC+LFE+SL+SR, and 7.1 carries
                # SL/SR as well as BL/BR, so a surround-only source measured
                # -91 dB (digital silence).  '5.1(side)' is the common layout in
                # this library, so most 5.1 content was losing its surrounds
                # entirely.  BC (4.0, 3.0(back), 6.1) and FLC/FRC (7.1(wide),
                # 6.0(front)) were dropped the same way.  Each channel below is
                # verified individually at its expected coefficient.
                #
                # This deliberately bypasses swresample's own downmix, which both
                # drops LFE outright (-91 dB measured on an LFE-only 5.1 source)
                # and normalises the result by its coefficient sum (5.1 -> stereo
                # measures -7.7 dB).  That normalisation is ffmpeg's clipping
                # guard, so a limiter takes over that job here -- libfdk_aac only
                # accepts s16 input, so anything over full scale would hard-clip.
                # The default audio_style="fold" re-encodes every channel at
                # fixed coefficients (the pan expression below).  The retry
                # ladder degrades this when a source's audio changes format
                # mid-stream and the fold chain cannot be reconfigured (see the
                # audio-degrade hook in run_job_transcode): "native" drops the
                # -af entirely and lets -ac/-ar downmix via a resampler that
                # reconfigures cleanly, and "copy" re-queues as a prune.
                if [[ "${audio_style:-fold}" == "fold" ]]; then
                    local af="pan=stereo"
                    af+="|FL=FL+0.707*FC+0.5*FLC+0.5*BL+0.5*BC+0.5*SL+0.5*TFL+0.5*TBL+0.5*LFE"
                    af+="|FR=FR+0.707*FC+0.5*FRC+0.5*BR+0.5*BC+0.5*SR+0.5*TFR+0.5*TBR+0.5*LFE"
                    if [[ "${AUDIO_LIMITER:-1}" -eq 1 ]]; then
                        # level=0 (auto level OFF) is load-bearing, not decoration.
                        # alimiter's default auto-level adds ~0.45 dB of makeup gain to
                        # quiet content, which breaks the fold's exact coefficients, and
                        # on hot content it lets the signal back up to 0.000 dB against a
                        # 0.95 limit -- i.e. it does not actually hold the ceiling it was
                        # given.  With level=0 the coefficients are exact (-6.020 dB for a
                        # 0.5 coefficient) and a full-scale downmix is held at -0.446 dB.
                        af+=",alimiter=limit=${AUDIO_LIMITER_LIMIT:-0.95}:level=0"
                    fi
                    audio_args="-af \"$af\" $audio_args"
                fi
            fi
            ;;
        prune)
            audio_map="-map 0:a:${audio_rel}"
            audio_args="-c:a copy"
            ;;
        *)
            audio_map="-map 0:a?"
            audio_args="-c:a copy"
            ;;
    esac

    local _sq="'"
    local video_path_sq="'${video_path//$_sq/$_sq\\$_sq$_sq}'"
    local output_path_sq="'${output_path//$_sq/$_sq\\$_sq$_sq}'"
    local ffmpeg_err_file_sq="'${ffmpeg_err_file//$_sq/$_sq\\$_sq$_sq}'"
    printf 'ffmpeg -y %s -v %s -progress "%s" -i %s -map 0:v:0 %s -map 0:s? -c:s copy %s %s %s 2>%s' \
        "$input_params" "$FFMPEG_LOGGING" "$progress_file" "$video_path_sq" \
        "$audio_map" "$video_params" "$audio_args" "$output_path_sq" "$ffmpeg_err_file_sq"
}

# Cheap sanity check on a completed attempt, used ONLY to decide whether the
# retry ladder should try a different strategy instead of accepting the result.
# Catches the symptoms that a different rung can plausibly fix: an output that is
# missing, empty, or truncated (which happens when a source with broken
# timestamps stops an encoder early even though it exited successfully).
output_looks_usable() {
    local output_path="$1" expected_duration="$2"
    if [[ ! -f "$output_path" || ! -s "$output_path" ]]; then
        return 1
    fi
    local d
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$output_path" 2>/dev/null)
    d=${d%%.*}
    [[ "$d" =~ ^[0-9]+$ ]] || return 1
    (( d > 0 )) || return 1
    if [[ "$expected_duration" =~ ^[0-9]+$ ]] && (( expected_duration > 0 )); then
        (( d >= expected_duration - DURATION_TOLERANCE )) || return 1
        (( d <= expected_duration + DURATION_TOLERANCE )) || return 1
    fi
    return 0
}

# Remove the staged output of a failed job.  Shared-memory jobs live in their
# own job folder; in-place jobs are a single temp file next to the source.
cleanup_output() {
    local output_path="$1" stage="${2:-shm}"
    if [[ "$stage" == "inplace" ]]; then
        [[ -f "$output_path" ]] && rm -f "$output_path" 2>/dev/null || true
        return 0
    fi
    cleanup_job_folder "$output_path"
}

# Path of the in-place staging file used by audio-only jobs on a given source.
inplace_temp_path() {
    local video_path="$1"
    local ext="${video_path##*.}"
    printf '%s.transcode-tmp.%s' "$video_path" "$ext"
}

# Containers we are willing to remux in place.  Anything else (avi, wmv, ts, ...)
# is left to the video path where the shm staging already handles it.
audio_only_container_ok() {
    local video_path="$1"
    local ext
    ext=$(printf '%s' "${video_path##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mkv|mp4|m4v|mov|webm) return 0 ;;
        *) return 1 ;;
    esac
}

get_media_info() {
    local video_path="$1"
    ffprobe -v quiet -print_format json -show_streams -show_format "$video_path"
}

# The FIRST line of ffmpeg's stderr is nearly always the informative one: with
# -v error the output contains only error text, and the last line is usually a
# generic "Terminating thread with return code ...".  Losing the first line is
# what made the exit-218 failures look like a mystery.
first_ffmpeg_error() {
    local err_file="$1"
    if [[ ! -s "$err_file" ]]; then
        return 0
    fi
    local first last
    first=$(grep -v '^[[:space:]]*$' "$err_file" 2>/dev/null | head -n 1 | tr -d '\r')
    last=$(grep -v '^[[:space:]]*$' "$err_file" 2>/dev/null | tail -n 1 | tr -d '\r')
    if [[ -n "$first" ]]; then
        if [[ -n "$last" && "$first" != "$last" ]]; then
            printf ' — %s … %s' "$first" "$last"
        else
            printf ' — %s' "$first"
        fi
    fi
    return 0
}

# Keep the full stderr of a failed attempt, trimmed to the most recent
# error_log_max_files entries, so a failure can be diagnosed after the fact.
save_ffmpeg_error() {
    local video_name="$1" job="$2" exit_code="$3" err_file="$4" attempt="$5"
    if [[ ! -s "$err_file" || -z "${ERROR_LOG_DIR:-}" ]]; then
        return 0
    fi
    mkdir -p "$ERROR_LOG_DIR" 2>/dev/null || return 0
    local stamp safe_name dest
    stamp=$(date '+%Y%m%d-%H%M%S')
    safe_name=$(printf '%s' "$video_name" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120)
    dest="$ERROR_LOG_DIR/${safe_name}.${stamp}.attempt${attempt}.exit${exit_code}.log"
    cp "$err_file" "$dest" 2>/dev/null || return 0

    local max_files="${ERROR_LOG_MAX_FILES:-200}"
    if [[ "$max_files" =~ ^[0-9]+$ ]] && (( max_files > 0 )); then
        ls -1t "$ERROR_LOG_DIR" 2>/dev/null | tail -n +"$(( max_files + 1 ))" | while IFS= read -r old; do
            rm -f "$ERROR_LOG_DIR/$old" 2>/dev/null || true
        done
    fi
    return 0
}

# Human-readable description of the audio rate actually in force.
#   $1 = configuration name
#   $2 = optional media path; when given, a container that cannot carry the
#        primary codec reports the fallback bitrate instead.
#   $3 = optional video_action; passed through to the container check so the
#        remapped output container decides (see container_supports_primary_audio).
# When VBR is active the configured bitrate is not passed to ffmpeg at all, so
# reporting it would be actively misleading in the log.
audio_rate_desc() {
    local config_name="$1" path="${2:-}" action="${3:-}"
    if [[ -n "$path" ]] && ! container_supports_primary_audio "$path" "$action"; then
        printf '%s' "$AUDIO_FALLBACK_BITRATE"
        return 0
    fi
    if [[ "${AUDIO_VBR:-0}" =~ ^[1-5]$ && "${AUDIO_ENCODER:-}" == "libfdk_aac" ]]; then
        printf 'VBR %s' "$AUDIO_VBR"
    else
        printf '%s' "${CONFIG_AUDIO_BITRATE[$config_name]:-$AUDIO_BITRATE}"
    fi
}

show_state() {
    local skipped_count skippederror_count skiptotal_count
    skipped_count=$(grep -v '^#' "$SKIP_FILE" 2>/dev/null | grep -c ',transcoded' || true)
    skipped_count=${skipped_count:-0}
    skiptotal_count=$(grep -v '^#' "$SKIP_FILE" 2>/dev/null | grep -c ',' || true)
    skiptotal_count=${skiptotal_count:-0}
    skippederror_count=$((skiptotal_count - skipped_count))
    write_log "Started processing on $HOSTNAME"
    echo ""
    echo "  Previously processed files: $skipped_count"
    echo "  Previously errored files: $skippederror_count"
    echo "  Total files to skip: $skiptotal_count"
    echo "  Global Settings - Threads: ${MIN_THREADS}-${MAX_THREADS} (VCN target: ${GPU_TARGET_PCT}%), Timeout: $FFMPEG_TIMEOUT, Restart Queue: $RESTART_QUEUE"
    local _arate _adown
    if [[ "${AUDIO_VBR:-0}" =~ ^[1-5]$ ]]; then _arate="VBR mode ${AUDIO_VBR}"; else _arate="${AUDIO_BITRATE}"; fi
    if [[ "${AUDIO_LFE_FOLD:-0}" -eq 1 ]]; then
        _adown="fold centre+surround+LFE into stereo"
        if [[ "${AUDIO_LIMITER:-1}" -eq 1 ]]; then _adown+=" + limiter ${AUDIO_LIMITER_LIMIT}"; fi
    else
        _adown="ffmpeg default (drops LFE, attenuates ~7.7dB on 5.1)"
    fi
    echo "  Audio - Target: ${AUDIO_CODEC} via ${AUDIO_ENCODER}, ${AUDIO_CHANNELS}ch @ ${_arate}, keep ${AUDIO_MAX_TRACKS} track(s), preferred languages: ${AUDIO_PREFERRED_LANGS}"
    echo "  Audio - Container: ${AUDIO_CODEC} for [${AUDIO_CONTAINERS}], ${AUDIO_FALLBACK_CODEC} @ ${AUDIO_FALLBACK_BITRATE} for anything else"
    echo "  Audio - Downmix: ${_adown}"
    echo "  Audio - Re-encode if: >${AUDIO_CHANNELS}ch, >${AUDIO_MIN_BITRATE_KBPS}kbps, or codec in [${AUDIO_ALWAYS_RECODE}]"
    echo "  Audio - Catch-up for already-encoded video: $([[ $AUDIO_CATCHUP -eq 1 ]] && echo enabled || echo disabled), max concurrent audio-only jobs: ${AUDIO_MAX_JOBS}"
    echo "  Retry ladder for video encodes: ${FFMPEG_RETRY_ATTEMPTS} attempt(s); failed-run details kept in ${ERROR_LOG_DIR} (last ${ERROR_LOG_MAX_FILES})"
    if [[ $AUDIO_ONLY -eq 1 ]]; then
        echo "  MODE: --audio-only — video streams are always copied, no video is re-encoded, no GPU required"
    fi
    if [[ $RETRY_FAILED -eq 1 ]]; then
        echo "  MODE: --retry-failed — crashed, early-aborted and duration-mismatch entries are being re-queued"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  DRY RUN - no files will be modified, no skip entries written (limit ${DRY_RUN_LIMIT} files)"
    fi
    if [[ $JOB_LIMIT -gt 0 && $DRY_RUN -eq 0 ]]; then
        echo "  LIMITED RUN - will process at most ${JOB_LIMIT} file(s) then stop"
    fi
    if [[ $MAX_SIZE_MB -gt 0 ]]; then
        echo "  SIZE CAP - only files up to ${MAX_SIZE_MB}MB will be processed"
    fi
    echo ""
    echo "  Loaded Configurations:"
    for config_name in "${CONFIG_NAMES[@]}"; do
        echo "    - $config_name:"
        echo "        Path: ${CONFIG_MEDIA_PATH[$config_name]}"
        echo "        Min Age: ${CONFIG_MIN_AGE[$config_name]} days, Min Size: ${CONFIG_MIN_SIZE[$config_name]} MB"
        echo "        Skip Codecs: ${CONFIG_SKIP_LIST[$config_name]}"
        echo "        FFmpeg Params: ${CONFIG_FFMPEG_PARAMS[$config_name]}"
        echo "        Audio Rate: $(audio_rate_desc "$config_name"), Max Tracks: ${CONFIG_AUDIO_MAX_TRACKS[$config_name]:-$AUDIO_MAX_TRACKS}"
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
    # The trailing -not clause keeps in-flight in-place staging files (written by
    # audio-only jobs) out of the scan; they end in a real media extension.
    find "$media_path" -type f \
        -not -name '*transcode-tmp*' \
        \( -iname '*.3g2' -o -iname '*.3gp' -o -iname '*.asf' -o -iname '*.avi' -o -iname '*.dav' -o -iname '*.dirac' -o -iname '*.drc' -o -iname '*.flv' -o -iname '*.gxf' -o -iname '*.ismv' -o -iname '*.ivf' -o -iname '*.m4v' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.mp2' -o -iname '*.mp4' -o -iname '*.mpeg' -o -iname '*.mpegts' -o -iname '*.mpg' -o -iname '*.m2ts' -o -iname '*.mxf' -o -iname '*.nut' -o -iname '*.ogg' -o -iname '*.ogv' -o -iname '*.ps' -o -iname '*.rm' -o -iname '*.roq' -o -iname '*.swf' -o -iname '*.ts' -o -iname '*.vc1' -o -iname '*.viv' -o -iname '*.vob' -o -iname '*.webm' -o -iname '*.wm' -o -iname '*.wmv' -o -iname '*.wtv' -o -iname '*.y4m' \) \
        -printf '%p\t%s\n' | sort -t$'\t' -k2 -nr >"$output_csv"
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
            # The scan lines are path<TAB>size (not comma-separated): media
            # filenames routinely contain commas, which would both shift the
            # size field and split the path on re-read.
            while IFS=$'\t' read -r video_path size; do
                # A blank size means the line is not new-format (e.g. a stale
                # comma-separated scan file left over from before the switch):
                # the whole line lands in video_path and there is no size field.
                [[ -n "$size" ]] || continue
                printf '%s\t%s\t%s\n' "$config_name" "$video_path" "$size" >> "$temp_merged"
            done < "$config_csv"
        fi
    done
    if [[ -s "$temp_merged" ]]; then
        sort -t$'\t' -k3 -nr "$temp_merged" > "$merged_csv"
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
    local video_action="${5:-encode}"
    local audio_action="${6:-none}"
    local audio_rel="${7:--1}"
    local meta="${8:-}"
    local video_duration="${9:-0}"
    local done_reason="${10:-transcoded}"
    local video_name="${video_path##*/}"
    local video_size
    if [[ "$scan_size_bytes" -gt 0 ]]; then
        video_size=$((scan_size_bytes / 1024 / 1024))
    else
        video_size=$(stat --format=%s "$video_path" 2>/dev/null)
        video_size=$((video_size / 1024 / 1024))
    fi

    # Source metadata normally comes from the main loop's probe, so each file is
    # probed once rather than once before dispatch and again here.
    local video_codec audio_codec audio_channels audio_bitrate audio_width audio_height audio_count audio_fps
    if [[ -z "$meta" ]]; then
        local probe_json
        probe_json=$(get_media_info "$video_path")
        meta=$(parse_media_meta "$probe_json")
        video_duration=$(resolve_duration "$probe_json")
    fi
    IFS='|' read -r video_codec audio_codec audio_channels audio_bitrate _ _ audio_count _ _ audio_width audio_height audio_fps <<<"$meta"

    # Expected total frame count, used by the monitor as a progress signal that
    # does not depend on the output timeline (see monitor_progress).  Matroska
    # does not carry nb_frames, so derive it from duration x frame rate.
    local total_frames=0
    if [[ "$video_duration" =~ ^[0-9]+$ ]] && (( video_duration > 0 )) \
        && [[ "$audio_fps" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        local fps_num=$(( 10#${BASH_REMATCH[1]} )) fps_den=$(( 10#${BASH_REMATCH[2]} ))
        if (( fps_num > 0 && fps_den > 0 )); then
            total_frames=$(( video_duration * fps_num / fps_den ))
        fi
    fi

    local video_age
    video_age=$(get_video_age "$video_path")
    if [[ "${audio_count:-0}" -eq 0 ]]; then
        write_log "$job $video_name ERROR: no audio streams detected, deleting source file"
        write_skip "$video_path" "no-audio-source"
        rm -f "$video_path"
        return 1
    fi

    local video_encoding=0
    if [[ "$video_action" == "encode" ]]; then
        video_encoding=1
    fi

    # Fixed canvas used by the fallback rungs: the source's own first-video-stream
    # geometry, or a configured default when the probe did not report one.
    local canvas=""
    if [[ "$audio_width" =~ ^[0-9]+$ && "$audio_height" =~ ^[0-9]+$ ]] \
        && (( audio_width > 0 && audio_height > 0 )); then
        canvas="${audio_width}x${audio_height}"
    fi

    # Audio-only jobs stage in place: copying the video stream back out to
    # /dev/shm and then onto the share again would double the I/O for no reason.
    local stage="shm" output_path progress_file ffmpeg_err_file
    if [[ "$video_action" == "copy" ]]; then
        stage="inplace"
        output_path=$(inplace_temp_path "$video_path")
        rm -f "$output_path" 2>/dev/null || true
    else
        local job_folder="/dev/shm/ffmpeg-transcode/job_$(echo "$job" | tr -d '[]()')"
        output_path="$job_folder/${video_name%.*}.$(output_container_ext "$video_path")"
        if [[ -d "$job_folder" ]]; then
            rm -rf "$job_folder"
        fi
        mkdir -p "$job_folder"
    fi
    progress_file="/tmp/ffmpeg_progress_${BASHPID}"
    ffmpeg_err_file="/tmp/ffmpeg_err_${BASHPID}"
    rm -f "$progress_file"

    local start_time
    start_time=$(date +%s)
    local audio_desc="$audio_codec(${audio_channels}ch)"
    if [[ "$audio_count" -gt 1 ]]; then
        audio_desc="$audio_codec(${audio_channels}ch x${audio_count})"
    fi
    local action_desc
    if [[ "$video_action" == "copy" ]]; then
        action_desc="audio-only remux (video copied, not re-encoded)"
    else
        action_desc="video=encode"
    fi
    case "$audio_action" in
        encode) action_desc="$action_desc audio=$audio_codec->$(audio_codec_for "$video_path" "$video_action") ${AUDIO_CHANNELS}ch@$(audio_rate_desc "$config_name" "$video_path" "$video_action") (track $audio_rel)" ;;
        prune)  action_desc="$action_desc audio=prune to track $audio_rel" ;;
        none)   action_desc="$action_desc audio=keep" ;;
    esac
    write_log "$job $video_name ($video_codec, $audio_desc, $audio_width, ${video_size}MB, $video_age days old) $action_desc..."

    local ffmpeg_cmd
    # Retry ladder.  Rung 1 is the configured command.  Rung 2 normalises the
    # video onto a fixed canvas and disables filter-graph reinitialisation, which
    # is the documented fix for sources whose parameters change mid-stream (the
    # "Reconfiguring filter graph ... -38 Function not implemented" failure).
    # Rung 3 additionally drops hardware decoding.  Audio-only remuxes never
    # decode video, so they cannot hit that failure and are never retried.
    local max_attempts="${FFMPEG_RETRY_ATTEMPTS:-3}"
    if [[ "$video_action" != "encode" ]]; then
        max_attempts=1
    fi
    if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
        max_attempts=1
    fi

    local attempt=1 attempts_used=0 ffmpeg_pid=0 monitor_pid=0 ffmpeg_exit=0 monitor_rc=0
    local monitor_flag monitor_flag_content monitor_killed_ffmpeg
    # Audio pipeline strategy for this job.  Starts at "fold" (the exact pan +
    # limiter downmix); the degrade hook below steps it down to "native" (plain
    # -ac/-ar resample downmix) and then re-queues the job as a prune (copy the
    # chosen track) when the source's audio changes format mid-stream.
    local audio_style="fold"
    if [[ "${AUDIO_LFE_FOLD:-0}" -ne 1 ]]; then
        audio_style="native"
    fi
    while (( attempt <= max_attempts )); do
        rm -f "$output_path" "$progress_file" 2>/dev/null || true
        ffmpeg_cmd=$(build_ffmpeg_cmd "$config_name" "$video_path" "$video_action" "$audio_action" \
            "$audio_rel" "$output_path" "$progress_file" "$ffmpeg_err_file" "$attempt" "$canvas" "$audio_style")
        if (( attempt == 2 )); then
            write_log "$job $video_name WARN: retrying on a fixed ${canvas:-source} canvas with filter reinitialisation disabled"
        elif (( attempt == 3 )); then
            write_log "$job $video_name WARN: retrying with software decoding"
        elif (( attempt >= 4 )); then
            write_log "$job $video_name WARN: retrying with timestamp repair (-fflags +igndts+genpts)"
        fi
        # Launch ffmpeg in a subshell that execs the encoder.  Because the
        # subshell replaces itself with ffmpeg (via exec), $! is the PID of the
        # actual encoder process, not an idle bash wrapper.  This makes kill/wait
        # on the PID reliable and prevents orphaned wrappers from keeping pipe
        # fds open.
        (
            eval "exec nice -n $FFMPEG_NICE_PRIORITY $ffmpeg_cmd"
        ) &
        ffmpeg_pid=$!
        monitor_progress "$progress_file" "$scan_size_bytes" "$ffmpeg_pid" "$job" "$video_name" "$video_duration" "$output_path" "$ffmpeg_err_file" "$video_encoding" "$stage" "$total_frames" &
        monitor_pid=$!
        monitor_rc=0
        wait "$monitor_pid" 2>/dev/null || monitor_rc=$?
        monitor_rc=${monitor_rc:-0}

        ffmpeg_exit=0
        wait "$ffmpeg_pid" 2>/dev/null || ffmpeg_exit=$?
        ffmpeg_exit=${ffmpeg_exit:-0}
        attempts_used=$attempt

        if [[ $monitor_rc -eq 2 ]]; then
            break
        fi
        if [[ $ffmpeg_exit -eq 0 ]]; then
            # ffmpeg reported success.  Before accepting it, make sure it did not
            # quietly produce a truncated or empty file - which is what happens
            # when a source with broken timestamps stops an encoder early.  If it
            # did and rungs remain, try the next strategy rather than recording a
            # terminal failure on the first attempt.
            if (( attempt < max_attempts )) && ! output_looks_usable "$output_path" "$video_duration"; then
                local bad_duration
                bad_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$output_path" 2>/dev/null)
                bad_duration=${bad_duration%%.*}
                write_log "$job $video_name WARN: attempt ${attempt}/${max_attempts} produced an unusable output (duration ${bad_duration:-none}s vs source ${video_duration}s); retrying"
                # NB: remove only the bad output file.  cleanup_output would
                # delete the whole job folder, which the next attempt needs.
                rm -f "$output_path" 2>/dev/null || true
                kill "$monitor_pid" 2>/dev/null || true
                wait "$monitor_pid" 2>/dev/null || true
                rm -f "/tmp/monitor_kill_${ffmpeg_pid}" 2>/dev/null || true
                attempt=$(( attempt + 1 ))
                continue
            fi
            break
        fi
        # Reap the monitor before the next attempt: a stale monitor shares the
        # same progress-file path and could otherwise act on the next attempt.
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        rm -f "/tmp/monitor_kill_${ffmpeg_pid}" 2>/dev/null || true
        # Preserve the failure output of every attempt, not just the last.
        save_ffmpeg_error "$video_name" "$job" "$ffmpeg_exit" "$ffmpeg_err_file" "$attempt" || true
        # Audio-degrade fallback.  The retry ladder only changes VIDEO
        # strategies, so a source whose audio refuses the fold chain fails all
        # remaining rungs identically and the file is blacklisted (measured:
        # Hijack S01E01/E04, E-AC-3 JOC/Atmos, "Changing audio frame properties
        # on the fly is not supported" on every attempt).  When the failure
        # signature is the audio one, step the audio strategy down for the
        # attempts that remain: first to a plain resample downmix (its
        # resampler reconfigures cleanly, unlike the negotiated pan input),
        # then to copying the chosen track verbatim (prune) — it keeps the
        # stereo/5.1 track the user picked instead of losing the file.
        if [[ "$video_action" == "encode" && "$audio_action" == "encode" ]] \
            && grep -qiE 'audio frame properties' "$ffmpeg_err_file" 2>/dev/null; then
            if [[ "$audio_style" == "fold" ]]; then
                audio_style="native"
                write_log "$job $video_name WARN: audio fold chain failed (source audio changes format mid-stream); retrying with a plain stereo downmix"
            elif [[ "$audio_style" == "native" ]]; then
                audio_style="copy"
                audio_action="prune"
                write_log "$job $video_name WARN: audio downmix also failed; retrying with the chosen track copied instead of re-encoded"
            fi
        fi
        attempt=$(( attempt + 1 ))
    done

    if [[ $monitor_rc -eq 2 ]]; then
        # Monitor initiated an early abort; the monitor has already cleaned up
        # artifacts and returned a distinct exit code. Log the outcome, mark the
        # file as skipped, and return the abort code to the caller.
        write_log "$job $video_name INFO: transcode aborted early by monitor due to size inefficiency"
        write_skip "$video_path" "early-abort-size-inefficient"
        return 2
    elif [[ $ffmpeg_exit -eq 0 ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        rm -f "/tmp/monitor_kill_${ffmpeg_pid}" "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
        if ! post_transcode_checks "$video_path" "$output_path" "$video_name" "$video_codec" "$audio_codec" \
                "$video_duration" "$video_size" "$job" "$start_time" "$stage" "$video_action" "$audio_action" "$done_reason"; then
            return 1
        fi
    else
        monitor_flag_content=""
        local ffmpeg_err_detail=""
        monitor_killed_ffmpeg=0
        monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
        if [[ -f "$monitor_flag" ]]; then
            monitor_killed_ffmpeg=1
            monitor_flag_content=$(cat "$monitor_flag" 2>/dev/null || true)
            rm -f "$monitor_flag" 2>/dev/null || true
        fi
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        ffmpeg_err_detail=$(first_ffmpeg_error "$ffmpeg_err_file")
        rm -f "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
        if [[ $monitor_killed_ffmpeg -eq 1 ]]; then
            write_log "$job $video_name ERROR: ffmpeg killed by monitor (output larger than original or early abort)"
            write_skip "$video_path" "killed-by-monitor"
            cleanup_output "$output_path" "$stage"
            return 1
        else
            write_log "$job $video_name ERROR: ffmpeg failed (exit ${ffmpeg_exit}) after ${attempts_used} attempt(s)${ffmpeg_err_detail}"
            if [[ -n "${ERROR_LOG_DIR:-}" ]]; then
                write_log "$job $video_name INFO: full ffmpeg output saved under ${ERROR_LOG_DIR}"
            fi
            write_skip "$video_path" "ffmpeg-crash-${ffmpeg_exit}"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
    fi
    return 0
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
    local stage="${6:-shm}"

    # Ensure ffmpeg is gone (safety net when the caller's own kill sequence may
    # have raced or the PID was reused).
    if [[ -n "$ffmpeg_pid" ]] && kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
        wait "$ffmpeg_pid" 2>/dev/null || true
    fi

    # Remove the partially written output (job folder or in-place temp file).
    cleanup_output "$output_path" "$stage"

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
    local video_encoding="${9:-1}"
    local stage="${10:-shm}"
    local total_frames="${11:-0}"
    local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
    local last_log_time=0
    local now
    # Progress-signal bookkeeping.  out_time_us can stall on sources with broken
    # or non-monotonic timestamps; the frame counter does not.
    local prev_elapsed_us=0 prev_total_size=0 stall_polls=0 stall_reported=0

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

        # Early-abort condition: once a tenth of the file has been encoded, the
        # output should still be well under a tenth of the original size.  The
        # allowable size threshold then scales with progress, so the comparison
        # is always "output so far" versus "progress so far" of the source.
        #
        # Progress is taken from the FRAME counter in preference to out_time_us:
        # on sources with non-monotonic timestamps ffmpeg's reported out_time can
        # freeze for minutes while frames keep being encoded, which makes the
        # projected final size (and therefore this check) meaningless.  The
        # resulting file is still correct - only the reported time is wrong.
        #
        # Both size guards only make sense when the video is being re-encoded: an
        # audio-only remux copies the video stream verbatim, so the output
        # legitimately reaches ~100% of the source size almost immediately.
        local pct=""
        local pct_basis=""
        if (( total_frames > 0 )) && [[ "$frame" =~ ^[0-9]+$ ]] && (( frame > 0 )); then
            pct=$(( frame * 100 / total_frames ))
            pct_basis="frame ${frame}/${total_frames}"
        elif [[ -n "$elapsed_us" ]] && (( video_duration > 0 )); then
            pct=$(( elapsed_us * 100 / 1000000 / video_duration ))
            pct_basis="elapsed ${elapsed_sec}s/${video_duration}s"
        fi

        # Detect a stalled out_time while the output keeps growing.  Only the
        # time-based basis can stall; if it does, do not trust the projection.
        if [[ -n "$elapsed_us" && "$total_size" =~ ^[0-9]+$ ]]; then
            if (( elapsed_us <= prev_elapsed_us )) && (( total_size > prev_total_size )); then
                stall_polls=$(( stall_polls + 1 ))
            else
                stall_polls=0
            fi
            prev_elapsed_us=$elapsed_us
            prev_total_size=$total_size
        fi
        if (( stall_polls >= 1 )) && [[ "$pct_basis" == elapsed* ]]; then
            if (( stall_reported == 0 )); then
                write_log "$job $video_name WARN: output timeline is not advancing (source timestamps look broken); disabling the size-efficiency early abort for this job - the output file itself is still fine"
                stall_reported=1
            fi
            pct=""
        fi

        if [[ ${video_encoding:-1} -eq 1 && -n "$pct" && "$pct" -ge 10 && \
              "$original_size_bytes" -gt 0 && "$total_size" =~ ^[0-9]+$ ]]; then
            local size_threshold=$(( original_size_bytes * pct / 100 ))
            # Avoid integer-rounding to zero on very small files; require at least one byte.
            [[ $size_threshold -lt 1 ]] && size_threshold=1
            if [[ "$total_size" -ge "$size_threshold" ]]; then
                local current_mb=$((total_size / 1024 / 1024))
                local threshold_mb=$((size_threshold / 1024 / 1024))
                local source_mb=$((original_size_bytes / 1024 / 1024))
                local projected_mb=$(( total_size * 100 / pct / 1024 / 1024 ))
                write_log "$job $video_name WARN: at ${pct}% (${pct_basis}) output ${current_mb}MB >= proportional threshold ${threshold_mb}MB; projects to ${projected_mb}MB vs original ${source_mb}MB — aborting early"
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
                abort_early_cleanup "$output_path" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid" "$stage"
                return 2
            fi
        fi

        if [[ ${video_encoding:-1} -eq 1 && "$total_size" =~ ^[0-9]+$ && "$total_size" -gt "$original_size_bytes" ]]; then
            local current_mb=$((total_size / 1024 / 1024))
            local original_mb=$((original_size_bytes / 1024 / 1024))
            # Only kill if it's significantly larger (e.g., > 5 MB larger)
            if (( current_mb > original_mb + 5 )); then
                write_log "$job $video_name WARN: Output ($current_mb MB) significantly exceeds original ($original_mb MB), killing transcode"
                echo "output-too-large" > "$monitor_flag"
                kill -9 "$ffmpeg_pid" 2>/dev/null || true
                abort_early_cleanup "$output_path" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid" "$stage"
                return 2
            fi
        fi

        now=$(date +%s)
        if [[ $((now - last_log_time)) -ge 30 ]]; then
            # Report the same progress basis the abort logic used, so the log is
            # consistent even when the timeline is stalled.
            write_log "$job $video_name progress: ${pct:-?}% (${pct_basis:-unknown}) elapsed=${elapsed_sec:-?}s frame=${frame:-?} fps=${fps:-?} speed=${speed:-?}"
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
    local stage="${10:-shm}"
    local video_action="${11:-encode}"
    local audio_action="${12:-none}"
    local done_reason="${13:-transcoded}"

    if [[ ! -f "$output_path" ]]; then
        write_log "$job $video_name ERROR - output not found"
        write_skip "$video_path" "output-not-found"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    # Test the raw byte count: rounding to MB first would reject any legitimate
    # output smaller than 1 MB as "zero size".
    local video_new_size_bytes video_new_size_mb
    video_new_size_bytes=$(stat --format=%s "$output_path" 2>/dev/null)
    video_new_size_bytes=${video_new_size_bytes:-0}
    if [[ "$video_new_size_bytes" -eq 0 ]]; then
        write_log "$job $video_name ERROR, zero file size, File NOT moved"
        write_skip "$video_path" "zero-size"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    video_new_size_mb=$((video_new_size_bytes / 1024 / 1024))
    local new_media_info_json
    new_media_info_json=$(get_media_info "$output_path")
    local video_new_videocodec video_new_audiocodec video_new_channels video_new_audio_count
    local _new_meta
    _new_meta=$(printf '%s' "$new_media_info_json" | jq -r '
        [
            ([.streams[] | select(.codec_type=="video") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .codec_name] | first) // "null",
            ([.streams[] | select(.codec_type=="audio") | .channels] | first) // 0,
            ([.streams[] | select(.codec_type=="audio")] | length)
        ] | map(tostring) | join("|")
    ' 2>/dev/null)
    IFS='|' read -r video_new_videocodec video_new_audiocodec video_new_channels video_new_audio_count <<<"$_new_meta"
    local video_new_duration
    video_new_duration=$(resolve_duration "$new_media_info_json")
    # Downside: a small RELATIVE slack on top of DURATION_TOLERANCE.  When a
    # source exposes no stream-level duration signal the expected value falls
    # back to the container duration, which can exceed the true video span by
    # trailing audio/subtitle padding.  A purely fixed floor then rejects a
    # perfectly faithful re-encode -- measured: Gifted (2017), container 6125 s
    # vs actual video 6070 s, encode 6070 s, wrongly failed.  2% of a 2-hour
    # film is ~144 s, which absorbs that pad while still flagging real
    # truncations (the observed genuine failure, Mission Impossible Fallout,
    # lost 88%).  The upside stays strict: a longer output is always wrong.
    local _downs=$(( video_duration / 50 ))
    (( _downs < DURATION_TOLERANCE )) && _downs=$DURATION_TOLERANCE
    if [[ -z "$video_new_duration" || "$video_new_duration" -eq 0 \
        || $video_new_duration -lt $((video_duration - _downs)) \
        || $video_new_duration -gt $((video_duration + DURATION_TOLERANCE)) ]]; then
        write_log "$job $video_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved"
        write_skip "$video_path" "duration-mismatch"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    if [[ -z "$video_new_videocodec" || "$video_new_videocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no video stream detected, File NOT moved"
        write_skip "$video_path" "no-video-stream"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    if [[ -z "$video_new_audiocodec" || "$video_new_audiocodec" == "null" ]]; then
        write_log "$job $video_name ERROR, no audio stream detected, File NOT moved"
        write_skip "$video_path" "no-audio-stream"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    # A copy job must leave the video stream exactly as it was.
    if [[ "$video_action" == "copy" && "$video_new_videocodec" != "$video_codec" ]]; then
        write_log "$job $video_name ERROR, video codec changed on an audio-only job ($video_codec -> $video_new_videocodec), File NOT moved"
        write_skip "$video_path" "video-codec-changed"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    # Verify the audio we asked for actually landed.
    if [[ "$audio_action" == "encode" ]]; then
        # Which codec this container was supposed to get (see the helper above).
        if [[ "$video_new_audiocodec" != "$(audio_codec_for "$video_path" "$video_action")" ]]; then
            write_log "$job $video_name ERROR, expected audio codec $(audio_codec_for "$video_path" "$video_action") but got $video_new_audiocodec, File NOT moved"
            write_skip "$video_path" "audio-codec-mismatch"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
        if [[ "$video_new_channels" != "$AUDIO_CHANNELS" ]]; then
            write_log "$job $video_name ERROR, expected $AUDIO_CHANNELS audio channels but got $video_new_channels, File NOT moved"
            write_skip "$video_path" "audio-channel-mismatch"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
    fi
    if [[ "$audio_action" != "none" && "${video_new_audio_count:-0}" -gt 1 ]]; then
        write_log "$job $video_name ERROR, expected a single audio track but output has $video_new_audio_count, File NOT moved"
        write_skip "$video_path" "audio-track-count"
        cleanup_output "$output_path" "$stage"
        return 1
    fi
    local diff_mb diff_percent
    diff_mb=$((video_size_mb - video_new_size_mb))
    if [[ $video_size_mb -eq 0 ]]; then
        diff_percent=0
    else
        diff_percent=$(((video_size_mb - video_new_size_mb) * 100 / video_size_mb))
    fi
    if [[ "$video_action" == "copy" ]]; then
        # Audio-only remux.  The video bytes are copied verbatim, so the only
        # saving is the audio we dropped or shrank; accept any reduction at all
        # rather than applying the video-oriented min/max reduction window.
        # Compared in bytes: rounding both sides to MB would make any file under
        # 1 MB look like "no change".
        local source_bytes
        source_bytes=$(stat --format=%s "$video_path" 2>/dev/null)
        source_bytes=${source_bytes:-0}
        if [[ "$video_new_size_bytes" -ge "$source_bytes" ]]; then
            write_log "$job $video_name ERROR, audio-only remux produced no size reduction (${video_size_mb}MB -> ${video_new_size_mb}MB), File NOT moved"
            write_skip "$video_path" "audio-no-reduction"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
    else
        # Relaxed check: only fail if it's way too big or way too small
        local max_size_limit=$((video_size_mb + 500))
        if [[ $video_new_size_mb -gt $max_size_limit ]]; then
            write_log "$job $video_name ERROR, output significantly larger than original (${video_size_mb}MB -> ${video_new_size_mb}MB), File NOT moved"
            write_skip "$video_path" "output-too-large"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
        if [[ $diff_percent -lt $FFMPEG_MIN_DIFF ]]; then
            write_log "$job $video_name ERROR, min difference too small (${diff_percent}% < ${FFMPEG_MIN_DIFF}%) ${video_size_mb}MB -> ${video_new_size_mb}MB, File NOT moved"
            write_skip "$video_path" "below-min-reduction"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
        if [[ $diff_percent -gt $FFMPEG_MAX_DIFF ]]; then
            write_log "$job $video_name ERROR, max too high (${diff_percent}% > ${FFMPEG_MAX_DIFF}%) ${video_size_mb}MB -> ${video_new_size_mb}MB, File NOT moved"
            write_skip "$video_path" "above-max-reduction"
            cleanup_output "$output_path" "$stage"
            return 1
        fi
    fi
    local end_time
    end_time=$(date +%s)
    local time_taken=$((end_time - start_time))
    local time_mins=$((time_taken / MINUTES_TO_SECONDS))
    local time_secs=$((time_taken % MINUTES_TO_SECONDS))
    local total_time_formatted="${time_mins}:${time_secs}"
    write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
    if [[ "$stage" == "inplace" ]]; then
        write_log "$job $video_name video codec $video_new_videocodec (copied, not re-encoded), audio codec $audio_codec -> $video_new_audiocodec"
    else
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
    fi
    if [[ $MOVE_FILE -eq 0 ]]; then
        write_log "$job $video_name SUCCESS, move file disabled, File NOT moved"
        if [[ "$stage" == "inplace" ]]; then
            # Never leave a staging file in the media tree when moving is off.
            rm -f "$output_path" 2>/dev/null || true
        fi
        return 0
    fi
    write_log "$job $video_name SUCCESS, moving file..."
    sleep "$SLEEP_BEFORE_MOVE"
    if [[ "$stage" == "inplace" ]]; then
        # Same directory, so this is an atomic rename: no second full copy of
        # the video stream back onto the share.
        mv -f "$output_path" "$video_path"
        write_skip "$video_path" "$done_reason"
    else
        # When the source's container was remapped (e.g. .avi -> .mkv, see
        # output_container_ext), the transcode replaces the original file: copy
        # to the remapped path, then remove the old one so the library does not
        # end up holding both.  Otherwise the copy goes onto the source path as
        # before.
        local dest_path="$video_path"
        local src_ext dst_ext
        src_ext=$(printf '%s' "${video_path##*.}" | tr '[:upper:]' '[:lower:]')
        dst_ext=$(output_container_ext "$video_path")
        if [[ "$src_ext" != "$dst_ext" ]]; then
            dest_path="${video_path%.*}.${dst_ext}"
        fi
        # Copy synchronously, then clean up.  A background cp + immediate rm
        # creates a race: if cp hasn't opened the file before rm removes it,
        # cp fails with "cannot stat".  Synchronous copy is reliable.
        cp "$output_path" "$dest_path"
        rm -f "$output_path"
        if [[ "$dest_path" != "$video_path" ]]; then
            rm -f "$video_path"
        fi
        write_skip "$dest_path" "$done_reason"
    fi
    cleanup_output "$output_path" "$stage"
    sleep "$SLEEP_AFTER_MOVE"
    return 0
}

# ============================================================================
# MAIN EXECUTION - INITIALIZATION & CONFIGURATION LOADING
# ============================================================================
check_dependencies
load_config "${CONFIG_FILE:-./transcode-config.json}"
# One instance at a time: two runs would fight over /dev/shm/ffmpeg-transcode
# (initialize_output_folder deletes it), the skip file and the scan CSVs.
# --dry-run is read-only, so it is allowed alongside a real run.
if [[ $DRY_RUN -eq 0 ]]; then
    LOCK_FILE=${CONFIG_GLOBAL["lock_file"]:-"./transcode.lock"}
    # NB: never add a redirection to this exec — `exec 9>file 2>/dev/null` would
    # permanently point the shell's own stderr at /dev/null.
    if ! exec 9>"$LOCK_FILE"; then
        echo "ERROR: cannot open lock file '$LOCK_FILE' for writing." >&2
        exit 3
    fi
    if ! flock -n 9; then
        echo "ERROR: another transcode.sh is already running (lock: $LOCK_FILE)." >&2
        echo "       Wait for it to finish, or use --dry-run to preview safely." >&2
        exit 3
    fi
fi
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
# Retry ladder for video encodes: 1 = no retry, 2 = fixed canvas +
# -reinit_filter 0, 3 = rung 2 plus software decode.
FFMPEG_RETRY_ATTEMPTS=${CONFIG_GLOBAL["ffmpeg_retry_attempts"]:-4}
ERROR_LOG_DIR=${CONFIG_GLOBAL["error_log_dir"]:-"./transcode-errors"}
ERROR_LOG_MAX_FILES=${CONFIG_GLOBAL["error_log_max_files"]:-200}
DAYS_TO_SECONDS=86400
MINUTES_TO_SECONDS=60
# DURATION_TOLERANCE, FFMPEG_MIN_DIFF, FFMPEG_MAX_DIFF, FFMPEG_NICE_PRIORITY,
# SLEEP_BEFORE_MOVE, SLEEP_AFTER_MOVE are set in load_config from JSON.
SCAN_AT_START=${CONFIG_GLOBAL["scan_at_start"]:-0}
MOVE_FILE=${CONFIG_GLOBAL["move_file"]:-0}
# shm reservation tuning for expected-output sizing (P0 fix)
SHM_RESERVE_SAFETY_PCT=${CONFIG_GLOBAL["shm_reserve_safety_pct"]:-130}
SHM_RESERVE_FLOOR_MB=${CONFIG_GLOBAL["shm_reserve_floor_mb"]:-200}
MUX_QUEUE_SIZE=${CONFIG_GLOBAL["mux_queue_size"]:-9999}
# --- Audio policy (see bash/AUDIO-TRANSCODE-PLAN.md) -----------------------
# One soundtrack is kept and re-encoded; extra tracks are dropped.
#
# AUDIO_CODEC is the *stream* codec name ffprobe reports back and is what the
# post-transcode check in verify_output compares against.  AUDIO_ENCODER is the
# libavcodec encoder actually handed to "-c:a" and may legitimately differ:
# libfdk_aac emits a stream whose codec_name is plain "aac", so setting
# audio_codec=libfdk_aac would fail that check on every single job.
AUDIO_CODEC=${CONFIG_GLOBAL["audio_codec"]:-aac}
AUDIO_ENCODER=${CONFIG_GLOBAL["audio_encoder"]:-$AUDIO_CODEC}
AUDIO_BITRATE=${CONFIG_GLOBAL["audio_bitrate"]:-224k}
# Containers that can actually carry AUDIO_CODEC, and what to use instead
# elsewhere.  Opus forces this: ffmpeg writes Opus into MP4 without complaint
# (yielding a file no player reads) and refuses MOV outright, so the codec is
# chosen per file by container_supports_primary_audio.
AUDIO_CONTAINERS=${CONFIG_GLOBAL["audio_containers"]:-"mkv,webm"}
AUDIO_FALLBACK_CODEC=${CONFIG_GLOBAL["audio_fallback_codec"]:-ac3}
AUDIO_FALLBACK_BITRATE=${CONFIG_GLOBAL["audio_fallback_bitrate"]:-224k}
# 1-5 selects libfdk_aac VBR mode (content-driven rate) and makes AUDIO_BITRATE
# a fallback that is not passed to ffmpeg at all.  0 = CBR at AUDIO_BITRATE.
AUDIO_VBR=${CONFIG_GLOBAL["audio_vbr"]:-0}
AUDIO_CHANNELS=${CONFIG_GLOBAL["audio_channels"]:-2}
AUDIO_SAMPLE_RATE=${CONFIG_GLOBAL["audio_sample_rate"]:-48000}
AUDIO_MAX_TRACKS=${CONFIG_GLOBAL["audio_max_tracks"]:-1}
AUDIO_MIN_BITRATE_KBPS=${CONFIG_GLOBAL["audio_min_bitrate_kbps"]:-448}
AUDIO_PREFERRED_LANGS=${CONFIG_GLOBAL["audio_preferred_languages"]:-"eng,en"}
AUDIO_ALWAYS_RECODE=${CONFIG_GLOBAL["audio_always_reencode_codecs"]:-"truehd,mlp,dts,flac,wavpack,alac,pcm_*"}
# When 1, fold centre/surround/LFE into the stereo pair (see build_ffmpeg_cmd).
# Off means swresample's own downmix, which drops LFE and attenuates the whole
# mix by its coefficient sum.  Both effects are measured, not assumed.
AUDIO_LFE_FOLD=${CONFIG_GLOBAL["audio_lfe_fold"]:-1}
AUDIO_LIMITER=${CONFIG_GLOBAL["audio_limiter"]:-1}
AUDIO_LIMITER_LIMIT=${CONFIG_GLOBAL["audio_limiter_limit"]:-0.95}
AUDIO_MAX_JOBS=${CONFIG_GLOBAL["audio_max_jobs"]:-3}
AUDIO_CATCHUP=${CONFIG_GLOBAL["audio_catchup"]:-1}
declare -A CONFIG_BV_MB
declare -A CONFIG_AUDIO_BITRATE
declare -A CONFIG_AUDIO_MAX_TRACKS
declare -A dur_lookup
for cfg in "${CONFIG_NAMES[@]}"; do
    CONFIG_BV_MB["$cfg"]=$(parse_bv "${CONFIG_FFMPEG_PARAMS[$cfg]}")
done
# Optional per-configuration audio overrides (movies usually want more bitrate
# than series).  Empty string means "use the global default".
while IFS=$'\t' read -r cfg_name a_bitrate a_tracks; do
    [[ -z "$cfg_name" ]] && continue
    CONFIG_AUDIO_BITRATE["$cfg_name"]="$a_bitrate"
    CONFIG_AUDIO_MAX_TRACKS["$cfg_name"]="$a_tracks"
done < <(jq -r '.configurations[] | [.name, (.audio_bitrate // ""), (.audio_max_tracks // "")] | @tsv' "${CONFIG_FILE:-./transcode-config.json}")

if [[ $DRY_RUN -eq 0 ]]; then
    initialize_output_folder
fi
show_state

# ============================================================================
# MAIN EXECUTION - MEDIA SCANNING & PREPARATION
# ============================================================================
SCAN_RESULTS="./scan_results.csv"
SCAN_RESULTS_TMP="./scan_results.tmp"
# A dry run reuses whatever scan already exists rather than scanning again.
if [[ $DRY_RUN -eq 1 ]]; then
    SCAN_AT_START=0
fi
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
    if [[ $DRY_RUN -eq 1 ]]; then
        # A dry run must not rewrite the scan CSVs out from under a real run
        # that may be using them.
        write_log "[INFO] Dry run: reusing existing $SCAN_RESULTS ($(wc -l <"$SCAN_RESULTS") files), no rescan"
    else
        # Only run scans in background if scan_results.csv exists and has at least 1 line
        (for config_name in "${CONFIG_NAMES[@]}"; do
            run_media_scan "$config_name"
        done
        merge_scan_results "$SCAN_RESULTS_TMP" && mv -f "$SCAN_RESULTS_TMP" "$SCAN_RESULTS") &
    fi
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
mapfile -t videos < "$SCAN_RESULTS"
declare -A skip_lookup

# Reasons that mean "this file is finished, never look at it again".  Every
# other reason is a hard error and is also terminal.
SKIP_FORMAT_VERSION=2
is_terminal_skip_reason() {
    case "${1:-}" in
        transcoded) return 0 ;;
        ffmpeg-crash-*|duration-mismatch|no-video-stream|no-audio-stream|no-audio-source) return 0 ;;
        output-not-found|zero-size|output-too-large) return 0 ;;
        below-min-reduction|above-max-reduction|killed-by-monitor) return 0 ;;
        early-abort-size-inefficient|audio-no-reduction) return 0 ;;
        audio-codec-mismatch|audio-channel-mismatch|audio-track-count|video-codec-changed) return 0 ;;
        *) return 1 ;;
    esac
}

# Before this version the skip file recorded only the video outcome: "codec-skip"
# meant the video was already AV1 and "transcoded" meant the video had been
# rewritten, but in both cases the audio had been copied verbatim (which is how
# 46-minute episodes ended up carrying 22 full-bitrate language tracks).  Those
# entries cannot be trusted to mean "audio is fine", so they are dropped once and
# the files are re-probed and re-classified.  Hard errors are preserved.
migrate_skip_file() {
    SKIP_NEEDS_MIGRATION=0
    if [[ ! -f "$SKIP_FILE" ]]; then
        return 0
    fi
    local first_line
    first_line=$(head -n 1 "$SKIP_FILE" 2>/dev/null || true)
    if [[ "$first_line" == "#format,${SKIP_FORMAT_VERSION}" ]]; then
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        # Do not rewrite anything, but do apply the migration in memory so the
        # preview reflects what a real run would actually do.
        write_log "[INFO] Dry run: skip file is pre-format-${SKIP_FORMAT_VERSION}; video-only outcomes will be re-checked for audio"
        SKIP_NEEDS_MIGRATION=1
        return 0
    fi
    local tmp="${SKIP_FILE}.migrate.$$"
    local kept=0 dropped=0 key reason line
    printf '#format,%s\n' "$SKIP_FORMAT_VERSION" >"$tmp"
    # Entries are path,reason where the reason is always the LAST comma field
    # and the path itself may contain commas, so split on the final comma only.
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%,*}"
        reason="${line##*,}"
        if is_terminal_skip_reason "$reason"; then
            printf '%s,%s\n' "$key" "$reason" >>"$tmp"
            kept=$((kept + 1))
        else
            dropped=$((dropped + 1))
        fi
    done <"$SKIP_FILE"
    mv -f "$tmp" "$SKIP_FILE"
    write_log "[INFO] Migrated skip file to format ${SKIP_FORMAT_VERSION}: ${kept} terminal entries kept, ${dropped} video-only outcomes queued for audio re-check"
}

# Re-queue files that stopped for a reason we now handle better: ffmpeg crashes
# (the retry ladder) and early size-efficiency aborts (which could be produced by
# a stalled progress clock rather than a genuinely non-shrinking file).  A backup
# of the skip file is kept.
retry_failed_from_skip() {
    if [[ ! -f "$SKIP_FILE" ]]; then
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        write_log "[INFO] Dry run: would re-queue ffmpeg-crash, early-abort and duration-mismatch entries from $SKIP_FILE"
        return 0
    fi
    local crashed aborted durmis
    crashed=$(grep -c ',ffmpeg-crash-' "$SKIP_FILE" 2>/dev/null || true)
    aborted=$(grep -c ',early-abort-size-inefficient' "$SKIP_FILE" 2>/dev/null || true)
    durmis=$(grep -c ',duration-mismatch' "$SKIP_FILE" 2>/dev/null || true)
    crashed=${crashed:-0}
    aborted=${aborted:-0}
    durmis=${durmis:-0}
    if [[ "$crashed" -eq 0 && "$aborted" -eq 0 && "$durmis" -eq 0 ]]; then
        write_log "[INFO] --retry-failed: nothing to re-queue in $SKIP_FILE"
        return 0
    fi
    # Drop only lines whose final field is one of the re-queueable reasons, so
    # path-keyed entries (which may themselves contain commas) survive intact.
    cp "$SKIP_FILE" "${SKIP_FILE}.bak" 2>/dev/null || true
    if awk -F, '{ r = $NF; if (r ~ /^ffmpeg-crash-/ || r == "early-abort-size-inefficient" || r == "duration-mismatch") next; print }' \
            "$SKIP_FILE" >"${SKIP_FILE}.tmp" 2>/dev/null; then
        mv -f "${SKIP_FILE}.tmp" "$SKIP_FILE"
    else
        rm -f "${SKIP_FILE}.tmp" 2>/dev/null || true
        write_log "[WARN] --retry-failed: could not rewrite $SKIP_FILE, nothing re-queued"
        return 1
    fi
    write_log "[INFO] --retry-failed: re-queued ${crashed} crashed, ${aborted} early-aborted and ${durmis} duration-mismatch file(s) (backup: ${SKIP_FILE}.bak)"
    return 0
}

load_skip_file() {
    if [[ -f "$SKIP_FILE" ]]; then
        local line filename reason
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Reason is the last comma field; the path (everything before it)
            # may itself contain commas, so do not split on every comma.
            filename="${line%,*}"
            reason="${line##*,}"
            # Pre-migration entries only recorded a video outcome, so only the
            # terminal ones can be trusted to mean "this file is finished".
            if [[ "${SKIP_NEEDS_MIGRATION:-0}" -eq 1 ]] && ! is_terminal_skip_reason "$reason"; then
                continue
            fi
            skip_lookup["$filename"]="${reason:-unknown}"
        done < "$SKIP_FILE"
    fi
}
migrate_skip_file
if [[ $RETRY_FAILED -eq 1 ]]; then
    retry_failed_from_skip
fi
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
dry_run_count=0
jobs_dispatched=0
max_size_notice=0
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
    # --limit: stop once this many files have been dispatched; the drain loop
    # after the main loop waits for them to finish.
    if [[ $JOB_LIMIT -gt 0 && $jobs_dispatched -ge $JOB_LIMIT ]]; then
        write_log "[INFO] --limit ${JOB_LIMIT} reached (${jobs_dispatched} job(s) dispatched); draining running jobs"
        break
    fi
    IFS=$'\t' read -r config_name video size <<<"${videos[$video_idx]}"
    if [[ $RESTART_QUEUE -ne 0 ]]; then
        now=$(date +%s)
        elapsed_minutes=$(( (now - queue_timer) / MINUTES_TO_SECONDS ))
        if [[ $elapsed_minutes -gt $RESTART_QUEUE ]]; then
            write_log "[INFO] Restart queue reached. Re-scanning..."
            for cfg_name in "${CONFIG_NAMES[@]}"; do
                run_media_scan "$cfg_name"
            done
            merge_scan_results "$SCAN_RESULTS"
            mapfile -t videos < "$SCAN_RESULTS"
            unset skip_lookup; declare -A skip_lookup
            load_skip_file
            video_idx=0
            queue_timer=$(date +%s)
            continue
        fi
    fi
    video_basename="${video##*/}"
    # The skip file has been path-keyed since format 2; the basename lookup keeps
    # legacy entries (which stored only the file name) working.  A file whose
    # audio has been fixed but whose video still needs work is NOT finished, so
    # it must stay in the queue.
    skip_reason="${skip_lookup[$video]:-${skip_lookup[$video_basename]:-}}"
    if [[ -n "$skip_reason" && "$skip_reason" != "audio-done-video-pending" ]]; then
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
    if [[ $MAX_SIZE_MB -gt 0 && $video_size_mb -gt $MAX_SIZE_MB ]]; then
        # Size-capped smoke-test mode.  The queue is sorted largest-first, so
        # once this trips it trips for everything after it; say so once.
        if [[ ${max_size_notice:-0} -eq 0 ]]; then
            write_log "[INFO] --max-size-mb $MAX_SIZE_MB: skipping files larger than ${MAX_SIZE_MB}MB (first: $video_basename at ${video_size_mb}MB)"
            max_size_notice=1
        fi
        video_idx=$((video_idx + 1))
        continue
    fi
    if [[ $video_size_mb -lt $min_size ]]; then
        write_log "HIT VIDEO SIZE LIMIT for config '$config_name' - waiting for running jobs to finish then quitting"
        exit 0
    fi
    video_age=$(get_video_age "$video")
    min_age="${CONFIG_MIN_AGE[$config_name]}"
    # A NEGATIVE age means the mtime is in the FUTURE -- a broken timestamp, not a
    # fresh download.  Without the >= 0 guard such a file is skipped as "too new"
    # on every run, forever: -4127 -lt 10 is always true.  Measured in this
    # library, Moffie (2020) carries mtime 2038-01-19 (the 32-bit time_t
    # rollover), which locked it out of processing permanently.
    if [[ $video_age -lt 0 ]]; then
        write_log "($((video_idx+1))) $video_basename has a future mtime ($video_age days) — broken timestamp, treating as eligible"
    elif [[ $video_age -lt $min_age ]]; then
        write_log "($((video_idx+1))) $video_basename ($video_size_mb MB, $video_age days old) too new, skipping"
        video_idx=$((video_idx + 1))
        continue
    fi

    # One probe per file. It drives the video decision, the audio decision, the
    # shm reservation and the job itself (run_job_transcode no longer re-probes).
    _meta_json=$(get_media_info "$video")
    _meta=$(parse_media_meta "$_meta_json")
    IFS='|' read -r pre_codec pre_audiocodec pre_achannels pre_abitrate _ _ pre_acount pre_alang _ _ <<<"$_meta"
    video_dur=$(resolve_duration "$_meta_json")
    dur_lookup["$video"]=$video_dur

    # ---- video axis: is the video already in a codec we do not re-encode? ----
    video_compliant=0
    video_codec_skip_list="${CONFIG_SKIP_LIST[$config_name]}"
    IFS=',' read -ra _skiplist <<<"$video_codec_skip_list"
    for _skip in "${_skiplist[@]}"; do
        [[ -z "$_skip" ]] && continue
        if [[ "$pre_codec" == "$_skip" ]]; then
            video_compliant=1
            break
        fi
    done
    video_action="encode"
    if [[ "$video_compliant" -eq 1 ]]; then
        video_action="copy"
    fi
    if [[ $AUDIO_ONLY -eq 1 ]]; then
        # Sweep mode: never re-encode video, whatever the codec.
        video_action="copy"
    fi

    # What to record when there is nothing left to do.  Only claim the file is
    # finished if its video is compliant; in audio-only mode a file whose video
    # still needs work must stay in the queue for a later normal run.
    if [[ "$video_action" == "encode" || "$video_compliant" -eq 1 ]]; then
        done_reason="transcoded"
    else
        done_reason="audio-done-video-pending"
    fi

    # ---- audio axis ----
    audio_rel=$(printf '%s' "$_meta" | cut -d'|' -f6)
    audio_action=$(decide_audio_action "$pre_audiocodec" "$pre_achannels" "$pre_abitrate" "$pre_acount" \
        "${CONFIG_AUDIO_MAX_TRACKS[$config_name]:-$AUDIO_MAX_TRACKS}")

    if [[ "$video_action" == "copy" && "$audio_action" == "none" ]]; then
        write_log "($((video_idx+1))) $video_basename (${video_size_mb}MB, $pre_codec/$pre_audiocodec) already compliant, skipping"
        write_skip "$video" "$done_reason"
        video_idx=$((video_idx + 1))
        continue
    fi
    if [[ "$video_action" == "copy" && "${AUDIO_CATCHUP:-1}" -ne 1 && $AUDIO_ONLY -eq 0 ]]; then
        write_log "($((video_idx+1))) $video_basename video already encoded, audio catch-up disabled, skipping"
        video_idx=$((video_idx + 1))
        continue
    fi
    if [[ "$video_action" == "copy" ]] && ! audio_only_container_ok "$video"; then
        # Deliberately not written to the skip file: if the policy ever changes
        # this should get another look, and skipping it only costs one probe.
        write_log "($((video_idx+1))) $video_basename video already encoded and '.${video##*.}' cannot be remuxed in place, skipping"
        video_idx=$((video_idx + 1))
        continue
    fi

    if [[ "$video_action" == "copy" ]]; then
        # Audio-only jobs stage in place next to the source, so /dev/shm is not
        # involved at all and they must not consume the shm budget.
        reserve_mb=0
    else
        # Reserve shm by EXPECTED output size (duration * target bitrate), not the
        # full source size. The AV1 output is a small fraction of the source, so
        # reserving the source size needlessly caps concurrency and starves the GPU.
        # Falls back to source size when duration is unknown.
        reserve_mb=$(calc_reserve "$config_name" "$video_size_mb" "$video_dur")
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_count=$((dry_run_count + 1))
        echo ""
        echo "[$dry_run_count] $video"
        printf '    source: %sMB, %s days old, %ss, %s audio track(s)\n' \
            "$video_size_mb" "$video_age" "$video_dur" "$pre_acount"
        if [[ "$video_action" == "copy" ]]; then
            printf '    video : %s -> copy (not re-encoded)\n' "$pre_codec"
        else
            printf '    video : %s -> encode\n' "$pre_codec"
        fi
        if [[ "$audio_action" == "encode" ]]; then
            printf '    audio : %s %sch (lang=%s) -> encode to %s via %s, %sch@%s, keeping track %s\n' \
                "$pre_audiocodec" "$pre_achannels" "${pre_alang:-unset}" \
                "$(audio_codec_for "$video" "$video_action")" "$(audio_encoder_for "$video" "$video_action")" "$AUDIO_CHANNELS" \
                "$(audio_rate_desc "$config_name" "$video" "$video_action")" "$audio_rel"
        else
            printf '    audio : %s %sch (lang=%s) -> %s, keeping track %s\n' \
                "$pre_audiocodec" "$pre_achannels" "${pre_alang:-unset}" "$audio_action" "$audio_rel"
        fi
        if [[ "$video_action" == "encode" && "${FFMPEG_RETRY_ATTEMPTS:-1}" -gt 1 ]]; then
            printf '    retry : up to %s attempt(s) on failure (fixed canvas, then software decode)\n' \
                "$FFMPEG_RETRY_ATTEMPTS"
        fi
        if [[ "$video_action" == "copy" ]]; then
            _out_preview=$(inplace_temp_path "$video")
        else
            # Mirror the real shm staging name, including the container remap.
            _out_preview="/dev/shm/ffmpeg-transcode/job_T1/${video_basename%.*}.$(output_container_ext "$video")"
        fi
        echo "    $(build_ffmpeg_cmd "$config_name" "$video" "$video_action" "$audio_action" \
            "$audio_rel" "$_out_preview" /tmp/ffmpeg_progress_dryrun /tmp/ffmpeg_err_dryrun)"
        if [[ $dry_run_count -ge $DRY_RUN_LIMIT ]]; then
            echo ""
            echo "Dry run complete: printed the next $dry_run_count files that would be processed."
            exit 0
        fi
        video_idx=$((video_idx + 1))
        continue
    fi
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
                    unset "JOB_TYPE_$thread"
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

                # Audio-only jobs use neither the GPU nor /dev/shm, so they need
                # their own cap; otherwise large concurrent remuxes would swamp
                # the share and slow the video jobs' reads.
                if [[ "$video_action" == "copy" ]]; then
                    running_audio=0
                    for ((t2 = 1; t2 <= MAX_THREADS; t2++)); do
                        t2_pid_var="JOB_PID_$t2"
                        t2_pid="${!t2_pid_var:-}"
                        if [[ -n "$t2_pid" ]] && kill -0 "$t2_pid" 2>/dev/null; then
                            t2_type_var="JOB_TYPE_$t2"
                            if [[ "${!t2_type_var:-video}" == "audio" ]]; then
                                running_audio=$((running_audio + 1))
                            fi
                        fi
                    done
                    if [[ $running_audio -ge ${AUDIO_MAX_JOBS:-3} ]]; then
                        now=$(date +%s)
                        if [[ $((now - last_wait_log)) -ge $GPU_CHECK_INTERVAL ]]; then
                            echo "[WAIT] ${AUDIO_MAX_JOBS} audio-only job(s) already running — waiting to start $video_basename"
                            last_wait_log=$now
                        fi
                        break
                    fi
                fi

                # If other jobs are holding shm and there isn't room, wait.
                if [[ $reserved_mb -gt 0 && $effective_free -lt $reserve_mb ]]; then
                    now=$(date +%s)
                    if [[ $((now - last_wait_log)) -ge $GPU_CHECK_INTERVAL ]]; then
                        echo "[WAIT] /dev/shm ${effective_free}MB spare after running-job reservations, need ${reserve_mb}MB for $video_basename — waiting for space (reservations are estimates, not allocated space)"
                        last_wait_log=$now
                    fi
                    break
                fi

                # Room available (or this is the only running job): dispatch the
                # current video into this free slot.
                run_job_transcode "$config_name" "$video" "[T${thread}]" "$size" \
                    "$video_action" "$audio_action" "$audio_rel" "$_meta" "$video_dur" "$done_reason" &
                new_pid=$!
                declare $pid_var=$new_pid
                declare $start_var="$(date +%s)"
                declare "JOB_SIZE_$thread=$reserve_mb"
                if [[ "$video_action" == "copy" ]]; then
                    declare "JOB_TYPE_$thread=audio"
                    INPLACE_TEMPS+=("$(inplace_temp_path "$video")")
                else
                    declare "JOB_TYPE_$thread=video"
                fi
                last_job_start=$(date +%s)
                jobs_dispatched=$((jobs_dispatched + 1))
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
                write_log "[STATUS] VCN=${vcn_pct}% threads=${actual_running}/${MAX_THREADS} shm=${shm_free_mb}MB free, ${reserved_mb}MB reserved by running jobs (${effective_free}MB spare) — ${scale_action}"
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
        # A failed job returns non-zero; without the guard `set -e` would abort
        # here and skip the remaining slots (leaving jobs running) instead of
        # draining the queue.
        wait "$pid" 2>/dev/null || true
    fi
done
write_log "Finished processing"
exit 0
