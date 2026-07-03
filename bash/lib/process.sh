#!/usr/bin/env bash
# process.sh – process-tree management, signal handlers, and temp-file cleanup

initialize_output_folder() {
    local output_path="${CONFIG_GLOBAL["output_path"]:-/dev/shm/ffmpeg-transcode}"
    if [[ ! -d "$output_path" ]]; then
        mkdir -p "$output_path"
    else
        rm -rf "${output_path:?}"/*
    fi
}

cleanup_shm() {
    local shm_path="/dev/shm/ffmpeg-transcode"
    [[ -d "$shm_path" ]] && rm -rf "$shm_path"
}

# Recursively print all descendant PIDs of a given root PID (one per line).
# The output is deepest-first so that callers can kill children before parents.
get_descendant_pids() {
    local parent="$1"
    local children
    children=$(pgrep -P "$parent" 2>/dev/null || true)
    [[ -z "$children" ]] && return
    local child
    for child in $children; do
        get_descendant_pids "$child"
        echo "$child"
    done
}

# Terminate a process and its entire descendant tree.  Children are killed
# before their parent so the parent cannot respawn them or leave them orphaned.
# SIGTERM is sent first with a short grace period, then SIGKILL for stragglers.
kill_tree() {
    local root="${1:-}"
    [[ -z "$root" ]] && return
    [[ "$root" == "$$" ]] && return   # never kill the main script itself
    if ! kill -0 "$root" 2>/dev/null; then
        return
    fi
    local descendants
    descendants=$(get_descendant_pids "$root")
    # SIGTERM every descendant, then the root.
    local pid
    for pid in $descendants "$root"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    # Give graceful shutdown a brief window.
    local waited=0
    while [[ $waited -lt 10 ]]; do
        if ! kill -0 "$root" 2>/dev/null; then
            break
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
    # SIGKILL anything still alive.
    for pid in $descendants "$root"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
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
    cleanup_shm
    # 128 + signal number: SIGINT=2, SIGTERM=15, SIGHUP=1
    case "$sig" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
        HUP) exit 129 ;;
        *) exit 137 ;;
    esac
}

cleanup_job_folder() {
    local output_path="$1"
    local job_folder
    job_folder=$(dirname "$output_path")
    if [[ -d "$job_folder" && "$job_folder" == *"/dev/shm/ffmpeg-transcode/"* ]]; then
        rm -rf "$job_folder"
    fi
}

abort_early_cleanup() {
    local output_path="$1"
    local progress_pipe="$2"
    local progress_file="$3"
    local ffmpeg_err_file="$4"
    local monitor_flag="$5"
    local ffmpeg_pid="${6:-}"

    # Ensure ffmpeg is gone (safety net when the caller's own kill sequence may
    # have raced or the PID was reused).  With the exec launch, $ffmpeg_pid is
    # the real encoder PID, so this is reliable.
    if [[ -n "$ffmpeg_pid" ]] && kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
        wait "$ffmpeg_pid" 2>/dev/null || true
    fi

    # Close the progress pipe so the sink sees EOF and exits.  This avoids
    # wait $progress_sink_pid blocking forever on an orphaned ffmpeg write fd.
    if [[ -n "$progress_pipe" ]] && [[ -p "$progress_pipe" ]]; then
        rm -f "$progress_pipe"
    fi

    # Remove the partially written output and its temporary job folder.
    cleanup_job_folder "$output_path"

    # Remove named pipe, progress capture, error log, and monitor flag.
    rm -f "$progress_pipe" "$progress_file" "$ffmpeg_err_file" "$monitor_flag" 2>/dev/null || true
}
