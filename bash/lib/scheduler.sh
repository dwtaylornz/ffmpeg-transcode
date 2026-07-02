#!/usr/bin/env bash
# scheduler.sh – main video processing loop with concurrency, OOO dispatch,
# and GPU-aware thread scaling.

# Constants for the scheduling loop
OOO_CHECK_INTERVAL=${OOO_CHECK_INTERVAL:-5}
WAIT_STEP=${WAIT_STEP:-0.1}
EXIT_SLEEP=${EXIT_SLEEP:-5}

# Try to dispatch a smaller out-of-order video when the current slot's video
# is too big for the available shm space. Returns 0 if dispatched, 1 otherwise.
_try_ooo_dispatch() {
    local thread="$1"
    local video_idx="$2"
    local effective_free="$3"
    local -n _done_flag=$4     # set to 1 on success

    local now
    now=$(date +%s)
    if [[ $((now - last_ooo_check)) -lt $OOO_CHECK_INTERVAL ]]; then
        return 1
    fi
    last_ooo_check=$now

    local vcn_ooo
    vcn_ooo=$(get_vcn_utilization)
    if [[ $vcn_ooo -ge $GPU_TARGET_PCT || $effective_free -le 0 ]]; then
        return 1
    fi

    local la la_cfg la_vid la_sz la_sz_mb la_base
    for ((la = video_idx + 1; la < ${#videos[@]}; la++)); do
        [[ -n "${dispatched_ooo[$la]:-}" ]] && continue
        IFS=',' read -r la_cfg la_vid la_sz <<<"${videos[$la]}"
        la_sz_mb=$((la_sz / 1024 / 1024))
        la_base="${la_vid##*/}"
        [[ -n "${skip_lookup[$la_base]:-}" ]] && continue
        [[ ! -f "$la_vid" ]] && continue
        [[ $la_sz_mb -lt ${CONFIG_MIN_SIZE[$la_cfg]} ]] && continue
        if [[ $la_sz_mb -le $effective_free ]]; then
            write_log "[OOO][T${thread}] $la_base (${la_sz_mb}MB) fits shm (${effective_free}MB free) — dispatching ahead"
            run_job_transcode "$la_cfg" "$la_vid" "[T${thread}]" "$la_sz" &
            local new_pid=$!
            declare -g "JOB_PID_$thread=$new_pid"
            declare -g "JOB_START_$thread=$(date +%s)"
            declare -g "JOB_SIZE_$thread=$la_sz_mb"
            last_job_start=$(date +%s)
            gpu_has_headroom=0
            low_vcn_streak=0
            dispatched_ooo[$la]=1
            _done_flag=1
            return 0
        fi
    done
    return 1
}

# Re-scan all configurations, rebuild the video list, and restart the queue.
_restart_queue() {
    local cfg_name
    write_log "[INFO] Restart queue reached. Re-scanning..."
    for cfg_name in "${CONFIG_NAMES[@]}"; do
        run_media_scan "$cfg_name"
    done
    merge_scan_results "$SCAN_RESULTS"
    mapfile -t videos < <(awk -F, '{print $0}' "$SCAN_RESULTS")
    unset skip_lookup; declare -gA skip_lookup
    unset dispatched_ooo; declare -gA dispatched_ooo
    load_skip_file
}

# Evaluate whether to grant a headroom scale-up based on VCN utilization
# averaged over the sampling window.
_evaluate_headroom() {
    local now video_size_mb
    now=$(date +%s)

    if [[ $((now - last_scale_check)) -lt $GPU_CHECK_INTERVAL ]] || \
       [[ $((now - last_job_start)) -lt $GPU_RAMP_WAIT ]]; then
        return
    fi
    last_scale_check=$now

    local vcn_pct shm_free_mb reserved_mb effective_free actual_running t t_pid_var t_pid t_size_var
    if [[ $vcn_sample_count -gt 0 ]]; then
        vcn_pct=$((vcn_sample_sum / vcn_sample_count))
    else
        vcn_pct=$(get_vcn_utilization)
    fi
    # Reset the sample window
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

    local scale_action
    if [[ $actual_running -eq 0 ]]; then
        gpu_has_headroom=0
        low_vcn_streak=0
        scale_action="idle — starting base task"
    elif [[ $vcn_pct -lt $GPU_TARGET_PCT ]]; then
        if [[ $actual_running -ge $MAX_THREADS ]]; then
            gpu_has_headroom=0
            low_vcn_streak=0
            scale_action="at max threads (${MAX_THREADS}/${MAX_THREADS})"
        elif [[ $effective_free -lt ${video_size_mb:-0} ]]; then
            gpu_has_headroom=0
            low_vcn_streak=0
            scale_action="waiting for shm"
        else
            low_vcn_streak=$((low_vcn_streak + 1))
            if [[ $low_vcn_streak -ge $GPU_HEADROOM_CONFIRM ]]; then
                gpu_has_headroom=1
                scale_action="headroom — scaling up ($((actual_running+1))/${MAX_THREADS})"
            else
                gpu_has_headroom=0
                scale_action="confirming headroom (${low_vcn_streak}/${GPU_HEADROOM_CONFIRM})"
            fi
        fi
    else
        gpu_has_headroom=0
        low_vcn_streak=0
        scale_action="GPU at load"
    fi

    if [[ $((now - last_status_log)) -ge $GPU_CHECK_INTERVAL ]]; then
        local shm_display=$((effective_free < 0 ? 0 : effective_free))
        write_log "[STATUS] VCN=${vcn_pct}% threads=${actual_running}/${MAX_THREADS} shm=${shm_display}MB available — ${scale_action}"
        last_status_log=$now
    fi
}

# Wait for all running jobs to finish.
wait_for_jobs() {
    local thread pid_var pid
    for ((thread = 1; thread <= MAX_THREADS; thread++)); do
        pid_var="JOB_PID_$thread"
        pid="${!pid_var:-}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
        fi
    done
}
