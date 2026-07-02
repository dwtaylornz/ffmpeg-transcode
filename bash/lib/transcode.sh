#!/usr/bin/env bash
# transcode.sh – core transcode job, progress monitor, and post-transcode validation

# ---------------------------------------------------------------------------
# Constants (tunable via environment or config, with sensible defaults)
# ---------------------------------------------------------------------------
MONITOR_SLEEP_INTERVAL=${MONITOR_SLEEP_INTERVAL:-5}
MONITOR_LOG_INTERVAL=${MONITOR_LOG_INTERVAL:-30}
MONITOR_GRACE_KILL=${MONITOR_GRACE_KILL:-5}
EARLY_ABORT_PCT=${EARLY_ABORT_PCT:-10}        # percentage of playback for first check
MIN_SIZE_EXCEED_MB=${MIN_SIZE_EXCEED_MB:-5}    # MB threshold before killing for oversize

run_job_transcode() {
    local config_name="$1"
    local video_path="$2"
    local job="$3"
    local scan_size_bytes="${4:-0}"
    local ffmpeg_output_params="${CONFIG_FFMPEG_PARAMS[$config_name]}"
    local video_name="${video_path##*/}"
    local video_size video_size_mb
    if [[ "$scan_size_bytes" -gt 0 ]]; then
        video_size_mb=$((scan_size_bytes / 1024 / 1024))
    else
        video_size_mb=$(du -m "$video_path" | awk '{print $1}')
    fi
    video_size=$video_size_mb

    # Get media info once, parse with shared helpers
    local media_json video_codec audio_codec audio_channels video_width video_duration_float video_duration_tag audio_stream_count
    media_json=$(get_media_info_json "$video_path")
    parse_media_meta "$media_json" video_codec audio_codec audio_channels video_width video_duration_float video_duration_tag audio_stream_count

    local video_duration=${video_duration_float%.*}
    parse_duration_from_tag "$video_duration_tag" video_duration

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

    local job_folder="/dev/shm/ffmpeg-transcode/job_${job//[()]/}"
    local output_path="$job_folder/$video_name"
    if [[ -d "$job_folder" ]]; then
        rm -rf "$job_folder"
    fi
    mkdir -p "$job_folder"

    # Use a named pipe for -progress so the monitor can read the latest line
    # without fighting file offsets and so parsing is non-blocking. A background
    # sink copies ffmpeg's progress lines to a regular file. The sink exits
    # automatically when ffmpeg closes the pipe.
    local progress_pipe="/tmp/ffmpeg_progress_${BASHPID}"
    local progress_file="/tmp/ffmpeg_progress_file_${BASHPID}"
    local ffmpeg_err_file="/tmp/ffmpeg_err_${BASHPID}"
    rm -f "$progress_pipe" "$progress_file"
    mkfifo "$progress_pipe"
    ( cat <"$progress_pipe" >"$progress_file" ) &
    local progress_sink_pid=$!

    local audio_map="-map 0:a?"
    local audio_codec_override=""
    if [[ "$audio_codec" == "null" ]]; then
        write_log "$job $video_name WARN: unidentified audio codec, re-encoding to AAC"
        audio_codec_override="-c:a aac -ac 2"
    fi

    local video_path_q output_path_q ffmpeg_err_file_q
    printf -v video_path_q    '%q' "$video_path"
    printf -v output_path_q   '%q' "$output_path"
    printf -v ffmpeg_err_file_q '%q' "$ffmpeg_err_file"

    local ffmpeg_cmd="ffmpeg -y \
        $FFMPEG_INPUT_PARAMS \
        -v $FFMPEG_LOGGING \
        -progress pipe:1 \
        -i $video_path_q \
        -map 0:v:0 $audio_map -map 0:s? \
        $ffmpeg_output_params \
        $audio_codec_override \
        $output_path_q 2>$ffmpeg_err_file_q"

    # Launch ffmpeg in a subshell that execs the encoder.  Because the subshell
    # replaces itself with ffmpeg (via exec), $! is the PID of the actual
    # encoder process, not an idle bash wrapper.
    (
        eval "exec nice -n $FFMPEG_NICE_PRIORITY $ffmpeg_cmd"
    ) >"$progress_pipe" &
    local ffmpeg_pid=$!

    monitor_progress "$progress_file" "$scan_size_bytes" "$ffmpeg_pid" "$job" "$video_name" "$video_duration" "$output_path" "$progress_pipe" "$ffmpeg_err_file" &
    local monitor_pid=$!
    local monitor_rc=0
    wait "$monitor_pid" 2>/dev/null || monitor_rc=$?
    monitor_rc=${monitor_rc:-0}

    local ffmpeg_exit=0
    wait "$ffmpeg_pid" 2>/dev/null || ffmpeg_exit=$?
    ffmpeg_exit=${ffmpeg_exit:-0}

    # Close the write side of the FIFO so the sink sees EOF and terminates cleanly.
    rm -f "$progress_pipe"

    # The sink can block if an orphaned process still holds the write fd, so
    # guard wait with a short timeout.
    local sink_done=0
    local _i
    for _i in {1..10}; do
        if ! kill -0 "$progress_sink_pid" 2>/dev/null; then
            sink_done=1
            break
        fi
        sleep 0.2
    done
    if [[ $sink_done -eq 0 ]]; then
        kill -9 "$progress_sink_pid" 2>/dev/null || true
    fi
    wait "$progress_sink_pid" 2>/dev/null || true

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
        rm -f "/tmp/monitor_kill_${ffmpeg_pid}" "$progress_pipe" "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
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
        rm -f "$progress_pipe" "$progress_file" "$ffmpeg_err_file" 2>/dev/null || true
        if [[ $monitor_killed_ffmpeg -eq 1 ]]; then
            write_log "$job $video_name ERROR: ffmpeg killed by monitor (output larger than original or early abort)"
            write_skip "$video_name" "killed-by-monitor"
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

# ---------------------------------------------------------------------------
# monitor_progress – polls ffmpeg -progress output every MONITOR_SLEEP_INTERVAL
# seconds. Aborts early if the output is already proportionally too large
# relative to the original file size.
# Returns 2 on early abort, 0 otherwise.
# ---------------------------------------------------------------------------
monitor_progress() {
    local progress_file="$1"
    local original_size_bytes="$2"
    local ffmpeg_pid="$3"
    local job="$4"
    local video_name="$5"
    local video_duration="$6"
    local output_path="${7:-}"
    local progress_pipe="${8:-}"
    local ffmpeg_err_file="${9:-}"
    local monitor_flag="/tmp/monitor_kill_${ffmpeg_pid}"
    local last_log_time=0
    local now

    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        sleep "$MONITOR_SLEEP_INTERVAL"
        [[ ! -f "$progress_file" ]] && continue

        # Extract the last complete progress stanza values (safe from set -u via defaults)
        local total_size out_time_us out_time_ms speed fps frame
        total_size=$(grep '^total_size=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        total_size="${total_size:-}"
        out_time_us=$(grep '^out_time_us=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        out_time_us="${out_time_us:-}"
        out_time_ms=$(grep '^out_time_ms=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        out_time_ms="${out_time_ms:-}"
        frame=$(grep '^frame=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        frame="${frame:-}"
        speed=$(grep '^speed=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        speed="${speed:-}"
        fps=$(grep '^fps=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)
        fps="${fps:-}"

        # Normalize elapsed time to microseconds
        local elapsed_us=""
        if [[ "${out_time_us:-}" =~ ^[0-9]+$ ]]; then
            elapsed_us=$out_time_us
        elif [[ "${out_time_ms:-}" =~ ^[0-9]+$ ]]; then
            elapsed_us=$out_time_ms
        fi
        local elapsed_sec=""
        if [[ -n "$elapsed_us" ]]; then
            elapsed_sec=$((elapsed_us / 1000000))
        fi

        # Early-abort condition: at EARLY_ABORT_PCT% of playback time the output should be
        # well under that same percentage of the original file size. Once past that point,
        # the allowable size threshold scales proportionally with playback progress.
        if [[ "$video_duration" -gt 0 && "$original_size_bytes" -gt 0 && \
              "${elapsed_us:-}" =~ ^[0-9]+$ ]]; then
            local tenth_time_us=$((video_duration * 1000000 / EARLY_ABORT_PCT))
            if [[ "$elapsed_us" -ge "$tenth_time_us" && \
                  "${total_size:-}" =~ ^[0-9]+$ ]]; then
                local pct=$((elapsed_us * 100 / 1000000 / video_duration))
                local size_threshold=$((original_size_bytes * pct / 100))
                # Avoid integer-rounding to zero on very small files
                [[ $size_threshold -lt 1 ]] && size_threshold=1
                if [[ "${total_size:-0}" -ge "$size_threshold" ]]; then
                    local current_mb=$((total_size / 1024 / 1024))
                    local threshold_mb=$((size_threshold / 1024 / 1024))
                    write_log "$job $video_name WARN: Reached ${pct}% playback (${elapsed_sec}s) with output ${current_mb}MB >= proportional threshold (${threshold_mb}MB), aborting transcode early"
                    echo "early-abort-10pct" > "$monitor_flag"
                    # SIGTERM asks ffmpeg to shut down cleanly; allow a short grace
                    # period, then force-kill if it is still alive.
                    kill "$ffmpeg_pid" 2>/dev/null || true
                    local grace=0
                    while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $grace -lt $MONITOR_GRACE_KILL ]]; do
                        sleep 1
                        grace=$((grace + 1))
                    done
                    kill -9 "$ffmpeg_pid" 2>/dev/null || true
                    abort_early_cleanup "$output_path" "$progress_pipe" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid"
                    return 2
                fi
            fi
        fi

        # Check if output is significantly exceeding original size
        if [[ "${total_size:-}" =~ ^[0-9]+$ ]] && [[ "${total_size:-0}" -gt "$original_size_bytes" ]]; then
            local current_mb=$((total_size / 1024 / 1024))
            local original_mb=$((original_size_bytes / 1024 / 1024))
            if (( current_mb > original_mb + MIN_SIZE_EXCEED_MB )); then
                write_log "$job $video_name WARN: Output ($current_mb MB) significantly exceeds original ($original_mb MB), killing transcode"
                echo "output-too-large" > "$monitor_flag"
                kill -9 "$ffmpeg_pid" 2>/dev/null || true
                abort_early_cleanup "$output_path" "$progress_pipe" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" "$ffmpeg_pid"
                return 2
            fi
        fi

        now=$(date +%s)
        if [[ $((now - last_log_time)) -ge $MONITOR_LOG_INTERVAL ]]; then
            local pct="?"
            if [[ "${out_time_us:-}" =~ ^[0-9]+$ && "$video_duration" -gt 0 ]]; then
                pct=$(( out_time_us * 100 / 1000000 / video_duration ))
            fi
            write_log "$job $video_name progress: ${pct}% elapsed=${elapsed_sec:-?}s frame=${frame:-?} fps=${fps:-?} speed=${speed:-?}"
            last_log_time=$(date +%s)
        fi
    done
    rm -f "$progress_file" "$monitor_flag" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# post_transcode_checks – validates the transcoded output
# ---------------------------------------------------------------------------
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
    video_new_size_mb=$(du -m "$output_path" | awk '{print $1}')
    if [[ $video_new_size_mb -eq 0 ]]; then
        write_log "$job $video_name ERROR, zero file size (${video_new_size_mb}MB), File NOT moved"
        write_skip "$video_name" "zero-size"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Get and parse new media info (reuses the shared helper)
    local new_media_json
    new_media_json=$(get_media_info_json "$output_path")
    local video_new_videocodec video_new_audiocodec video_new_channels video_new_width video_new_duration_float video_new_duration_tag video_new_audio_count
    parse_media_meta "$new_media_json" video_new_videocodec video_new_audiocodec video_new_channels video_new_width video_new_duration_float video_new_duration_tag video_new_audio_count

    local video_new_duration=${video_new_duration_float%.*}
    parse_duration_from_tag "$video_new_duration_tag" video_new_duration

    # Duration validation
    if [[ -z "$video_new_duration" || "$video_new_duration" -eq 0 || \
          $video_new_duration -lt $((video_duration - DURATION_TOLERANCE)) || \
          $video_new_duration -gt $((video_duration + DURATION_TOLERANCE)) ]]; then
        write_log "$job $video_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved"
        write_skip "$video_name" "duration-mismatch"
        cleanup_job_folder "$output_path"
        return 1
    fi

    # Stream presence validation
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

    # Size validation
    local diff_mb diff_percent
    diff_mb=$((video_size_mb - video_new_size_mb))
    compute_diff_percent "$video_size_mb" "$video_new_size_mb" diff_percent

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

    local end_time time_taken time_mins time_secs total_time_formatted
    end_time=$(date +%s)
    time_taken=$((end_time - start_time))
    time_mins=$((time_taken / MINUTES_TO_SECONDS))
    time_secs=$((time_taken % MINUTES_TO_SECONDS))
    total_time_formatted="${time_mins}:${time_secs}"

    if [[ $MOVE_FILE -eq 0 ]]; then
        write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
        write_log "$job $video_name SUCCESS, move file disabled, File NOT moved"
    else
        write_log "$job $video_name Transcode time: $total_time_formatted, Saved: ${diff_mb}MB (${video_size_mb}MB -> ${video_new_size_mb}MB) or ${diff_percent}%"
        write_log "$job $video_name video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec"
        write_log "$job $video_name SUCCESS, moving file (DO NOT BREAK DURING MOVE)..."
        sleep "$SLEEP_BEFORE_MOVE"
        mv -f "$output_path" "$video_path"
        write_skip "$video_name" "transcoded"
        sleep "$SLEEP_AFTER_MOVE"
        cleanup_job_folder "$output_path"
    fi
    return 0
}
