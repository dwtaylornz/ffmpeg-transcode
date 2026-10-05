# FFmpeg Video Transcoding Script

A powerful bash script for hardware-accelerated video transcoding using FFmpeg with VAAPI and AV1 encoding. This script is designed for Linux systems and provides efficient batch processing of video files with advanced features like multi-threading, error handling, and automatic queue management.

## Features

### Core Functionality
- **Hardware-Accelerated Encoding**: Uses VAAPI (Video Acceleration API) for efficient AV1 encoding
- **Dynamic Multi-Threading**: Configurable minimum/maximum simultaneous GPU jobs with automatic ramping based on GPU utilization
- **Batch Processing**: Automatically scans directories and processes multiple video files
- **Multiple Media Paths**: Supports separate configurations for different media libraries
- **Smart Skip Lists**: Maintains lists of processed and errored files to avoid reprocessing
- **Audio Re-encoding to Opus 2.0**: Keeps a single preferred-language audio track and re-encodes it to Opus stereo in the same pass as the video, dropping duplicate/lossless tracks that a stereo playback setup cannot use. Containers that cannot carry Opus (e.g. MP4 output) fall back to AC-3 at `audio_fallback_bitrate`

### Quality Control
- **Duration Validation**: Ensures transcoded files match original duration (±10 seconds tolerance)
- **Size Validation**: Configurable minimum/maximum file size reduction percentages
- **Codec Verification**: Validates video and audio streams in output files
- **Real-time Monitoring**: Monitors output file size during transcoding to prevent oversized outputs
- **10% Early-Abort**: Stops a transcode early when 10% of playback time has produced output already larger than 10% of the original file size, avoiding wasted encoding time on inefficient sources

### Management Features
- **Automatic Queue Restart**: Rescans directories and restarts queue after configurable time
- **Timeout Handling**: Kills stuck transcoding jobs after specified timeout
- **Age-based Processing**: Only processes files older than specified age
- **Size-based Processing**: Stops processing when reaching minimum file size threshold

## Requirements

- Linux operating system
- FFmpeg with VAAPI support
- Hardware with VAAPI-compatible GPU (Intel/AMD)
- `jq` for JSON parsing
- Bash 4.0 or later

## Configuration

Configuration is managed through the `transcode-config.json` file. Copy `transcode-config.json.example` to `transcode-config.json` and edit it to customize the following settings:

### Global Settings

```json
{
  "min_threads": 2,                       // Minimum simultaneous GPU jobs
  "max_threads": 8,                       // Maximum simultaneous GPU jobs
  "gpu_target_pct": 95,                   // Target GPU utilization before adding threads
  "gpu_ramp_wait": 30,                    // Seconds to wait for GPU utilization to ramp
  "gpu_check_interval": 30,               // Seconds between GPU utilization checks
  "scan_at_start": 1,                     // 0=background scan, 1=force scan, 2=no scan
  "restart_queue": 720,                   // Minutes before queue restart
  "ffmpeg_timeout": 6000,                 // Timeout per job (minutes)
  "ffmpeg_min_diff": 5,                   // Minimum size reduction percentage
  "ffmpeg_max_diff": 95,                  // Maximum size reduction percentage
  "move_file": 1,                         // 1=move files, 0=test mode

  "audio_codec": "opus",                  // Stream codec name ffprobe reports back
  "audio_encoder": "libopus",             // Encoder handed to -c:a (may differ from audio_codec)
  "audio_vbr": 0,                         // libfdk VBR mode 1-5 only; 0 = CBR at audio_bitrate
  "audio_bitrate": "128k",                // CBR target (not passed while audio_vbr is 1-5)
  "audio_containers": "mkv,webm",         // Containers that carry the primary codec (opus)
  "audio_fallback_codec": "ac3",          // Codec for containers that cannot carry opus
  "audio_fallback_bitrate": "224k",       // Fallback codec's bitrate
  "audio_channels": 2,                    // 2 = stereo downmix
  "audio_sample_rate": 48000,             // Output sample rate
  "audio_max_tracks": 1,                  // Keep at most this many audio tracks
  "audio_min_bitrate_kbps": 448,          // Re-encode a <=2ch track above this bitrate
  "audio_preferred_languages": "eng,en",  // Language preference order for track selection
  "audio_always_reencode_codecs": "truehd,mlp,dts,flac,wavpack,alac,pcm_*",
  "audio_lfe_fold": 1,                    // 1 = fold centre/surround/LFE into the stereo pair
  "audio_limiter": 1,                     // 1 = alimiter after the fold
  "audio_limiter_limit": 0.95,            // Limiter ceiling (linear)
  "audio_max_jobs": 3,                    // Max concurrent audio-only (remux) jobs
  "audio_catchup": 1,                     // 1 = also fix files whose video is already encoded

  "ffmpeg_retry_attempts": 4,             // Retry ladder for video encodes (1 = no retry)
  "error_log_dir": "./transcode-errors",  // Full ffmpeg stderr of failed attempts
  "error_log_max_files": 200,             // Keep only the most recent N error logs
  "lock_file": "./transcode.lock"         // Single-instance lock
}
```

### Per-Path Configurations

```json
{
  "configurations": [
    {
      "name": "movies",
      "media_path": "/videos/movies",
      "min_video_size": 0,
      "min_video_age": 10,
      "ffmpeg_output_params": "-vf 'format=nv12,hwupload' -c:v av1_vaapi -b:v 5M -maxrate 10M -bufsize 10M -max_muxing_queue_size 9999",
      "video_codec_skip_list": "av1",
      "audio_bitrate": "256k"
    }
  ]
}
```

`audio_bitrate` and `audio_max_tracks` may be set per configuration; anything
omitted falls back to the global value. Audio output options in
`ffmpeg_output_params` (such as `-c:a copy`) are stripped and replaced by the
script's own audio arguments, so they are no longer needed there.

`audio_codec` and `audio_encoder` are deliberately separate. In the shipped config
they match (`opus` is the stream codec, `libopus` the encoder), but some encoders
produce a stream whose `codec_name` differs from the encoder requested — e.g.
`libfdk_aac` produces a stream ffprobe reports as plain `aac` — so
`audio_codec` must always be the *stream* name the post-transcode check
compares against, or the check fails on every job. Leave `audio_encoder` unset to
use `audio_codec` as the encoder.

`audio_containers` lists the output containers that carry the primary codec
(`opus` here). Any other output container (notably MP4) gets the fallback:
`audio_fallback_codec` (`ac3`) at `audio_fallback_bitrate` (`224k`). The choice is
made per file from the container the output is actually written in — an `.avi` or
`.wmv` source is remapped to Matroska (see "Output Container Remapping") and
therefore gets Opus, not the AC-3 fallback.

## Usage

### Basic Usage

```bash
./transcode.sh
```

### Options

```bash
./transcode.sh --config /path/to/transcode-config.json
./transcode.sh --dry-run --limit 20     # preview, touch nothing
./transcode.sh --audio-only             # audio sweep: copy video, fix audio
./transcode.sh --retry-failed           # re-queue previously crashed files
./transcode.sh --max-size-mb 130 --limit 2   # fast smoke test on small files
./transcode.sh -h
```

`--dry-run` probes each file and prints the exact ffmpeg command that would run,
without executing ffmpeg, writing skip entries, deleting `/dev/shm/ffmpeg-transcode`,
rescanning the library, or modifying any media file. It is safe to run alongside a
real transcode.

`--audio-only` never re-encodes video, so it needs no GPU and does not compete
with the encoders for VCN time. It is the fastest way to reclaim the space held by
multi-track and lossless audio. Files whose video still needs work are marked
`audio-done-video-pending` and stay queued for a later normal run.

Only one real instance may run at a time (enforced with `flock` on `lock_file`);
`--dry-run` is exempt.

## File Structure

### Project Files

- `transcode-config.json` - Configuration file for all script settings (copy from `transcode-config.json.example`)
- `transcode.sh` - Main transcoding script

### Runtime Files (Generated During Execution)

- `transcode.log` - Main log file with timestamped entries (created during execution)
- `scan_results.csv` - Discovered video files and sizes. **Tab-separated** (`path<TAB>size`, then `config<TAB>path<TAB>size` after the merge), not comma-separated: media filenames routinely contain commas, which would split the path and shift the size field
- `skip.csv` - Files that are finished or terminally failed. Path-keyed; first line is a format header. Rows are `path,reason` with the reason always the **last** comma field, so paths that themselves contain commas round-trip intact
- `transcode-errors/` - Full ffmpeg stderr for each failed attempt (newest `error_log_max_files` kept)
- `transcode.lock` - Single-instance lock file
- `/dev/shm/ffmpeg-transcode/` - Temporary processing directory for video jobs (created during execution)
- `<media>.transcode-tmp.<ext>` - Transient staging file written next to the source by audio-only remux jobs, renamed over the source on success

### Supported Video Formats

- `.mkv`
- `.avi`
- `.ts`
- `.mov`
- `.y4m`
- `.m2ts`
- `.mp4`
- `.wmv`

### Output Container Remapping

ffmpeg picks the muxer from the output filename's extension, and several
muxers refuse the streams this pipeline produces.  A `.webm` source whose
copy keeps a non-WebVTT subtitle fails with *"Only VP8 or VP9 or AV1 video and
Vorbis or Opus audio and WebVTT subtitles are supported for WebM"* (on the
observed ffmpeg build that muxer error even segfaults the process, exit 139),
and the AVI/ASF muxers carry neither AV1 nor Opus at all.  The video-encode
path therefore writes the output under a container that can hold everything:

| Source extension | Output extension | Reason |
|------------------|------------------|--------|
| `.mkv`, `.mp4`   | unchanged        | known-good for av1 + opus/ac3 + arbitrary subs |
| anything else (`avi`, `wmv`, `webm`, `ts`, `mov`, `y4m`, ...) | `.mkv` | changing the filename is what changes the muxer |

On success the transcode **replaces the original file**: the old `.avi`/`.wmv`/...
is removed and the `.mkv` is kept in its place, so the library never holds both
copies.  The audio codec decision follows the *output* container — a remapped
file gets Opus, not the AC-3 fallback — and the post-transcode check validates
against the same output container.

Audio-only remuxes are unaffected: they stage in place, rename over the
source, and so keep the source's own container (which is why
`audio_only_container_ok` only permits mkv/mp4/m4v/mov/webm for in-place
remuxes in the first place).

## Transcoding Process

### 1. File Discovery
- Scans specified directory for supported video formats
- Sorts files by size (largest first)
- Generates CSV with file paths and sizes

### 2. Pre-Processing Checks
- Checks if file is in skip lists
- Validates file age against minimum age requirement
- Checks file size against minimum size threshold
- Verifies codec isn't in skip list

### 3. Transcoding
- Uses hardware-accelerated AV1 encoding with VAAPI
- Applies format conversion (nv12) and hardware upload
- Configures bitrate (3M), maxrate (5M), and buffer size (5M)
- Monitors output size in real-time
- Tracks FFmpeg `-progress` output to detect elapsed playback time and output bytes

### 4. 10% Early-Abort Check

During transcoding the monitor thread reads the FFmpeg `-progress` stream every 5 seconds. It extracts:
- `out_time_us` / `out_time_ms` — elapsed playback time in microseconds
- `total_size` — current output file size in bytes

When the encode has reached **10% of the original duration** (`video_duration / 10`) **and** the current output size has reached **10% of the original file size** (`original_size_bytes / 10`), the monitor concludes that the resulting file is unlikely to be smaller than the source and aborts the encode early.

What happens on early abort:
1. A warning is logged, e.g. `Reached 10% playback (XXs) with output YYMB >= 10% threshold (ZZMB), aborting transcode early`
2. FFmpeg is sent `SIGTERM` and allowed up to 5 seconds to exit cleanly.
3. If still running, it is killed with `SIGKILL`.
4. `abort_early_cleanup` removes the partial output and temporary files.
5. The source file is not modified.
6. The file is recorded in `skip.csv` with reason `early-abort-size-inefficient` so it will be skipped in future runs.

This earlier check complements the existing post-transcode size validation; it prevents the script from wasting time encoding the full duration of files that are clearly not going to yield useful space savings.

The size guards are skipped for jobs that copy the video stream (audio-only remuxes):
such a job legitimately reaches ~100% of the source size almost immediately, so the
comparison only makes sense while the video is actually being re-encoded.

**Progress is measured from the frame counter, not from `out_time`.** On sources with
broken or non-monotonic timestamps, ffmpeg's reported `out_time_us` can freeze for
minutes while frames keep being encoded (the output file itself is fine — only the
reported time is wrong). Comparing a growing output size against a threshold derived
from a frozen clock guarantees a false abort. The monitor therefore:

- derives progress from `frame / (duration x frame rate)`, which does not depend on
  the output timeline;
- falls back to `out_time_us` only when the frame rate is unknown, and in that case
  disables the abort entirely if the reported time stops advancing while bytes grow.

Both the abort message and the periodic progress line state which basis was used,
e.g. `at 13% (frame 40000/295850) output 5285MB >= threshold 3435MB; projects to
40653MB vs original 26425MB`.

### 5. Audio Re-encoding

Every job decides what to do with the audio independently of the video:

| Action | When | Effect |
|--------|------|--------|
| `encode` | chosen track has >`audio_channels` channels, bitrate above `audio_min_bitrate_kbps`, or a codec in `audio_always_reencode_codecs` | keep one track, re-encode to Opus stereo (`audio_fallback_codec` for containers that cannot carry Opus) |
| `prune` | more than `audio_max_tracks` tracks, but the chosen one is already fine | keep one track, copy it, drop the rest |
| `none` | single track, already compliant | leave the audio untouched |

The chosen track is the first one in `audio_preferred_languages`, falling back to
the track flagged `default`, then the first track. Language preference deliberately
outranks the default flag: multi-language WEB-DL releases in the wild routinely flag
a non-English track as default.

Jobs run in one of two modes:

- **video encode** (`video_action=encode`) — video plus audio in a single pass, staged
  in `/dev/shm` as before. No extra I/O is spent on the audio.
- **audio-only remux** (`video_action=copy`) — for files whose video is already in
  `video_codec_skip_list` but whose audio is not compliant. The video stream is copied
  verbatim, no GPU device is required, and the output is staged in place next to the
  source and then renamed over it (atomic, no second copy of the video). These jobs
  are capped separately by `audio_max_jobs` and consume no `/dev/shm`.

Set `audio_catchup: 0` to leave already-encoded video alone.

The audio decision follows the **output** container, not the source: a video-encode
job on an `.avi`/`.wmv`/`webm` source is remapped to Matroska (see "Output Container
Remapping"), so it gets Opus, and the post-transcode check validates against that
same output container. If a source's audio refuses the fold chain mid-stream
(E-AC-3 Atmos/JOC changes channel layout between frames), the retry ladder degrades
the audio strategy instead of blacklisting the file — see "Failure Diagnostics and
the Retry Ladder".

**Skip-list format change.** Prior to format 2, `skip.csv` recorded only a video
outcome (`transcoded`, `codec-skip`), and audio had been copied verbatim. Those
entries can no longer be trusted to mean "audio is fine", so on first run the script
migrates the file: terminal errors are kept, video-only outcomes are dropped so those
files are re-probed and, where needed, fixed by an audio-only remux. Entries are now
keyed by full path rather than file name (basename entries from older versions are
still honoured).

### 6. Post-Processing Validation
- Verifies output file exists and has non-zero size
- Checks duration matches original (±10 seconds)
- Validates video and audio streams
- Confirms the requested audio codec/channel count actually landed
- Confirms size reduction within configured limits (audio-only remuxes just have to be smaller)
- Moves processed file to replace original (if enabled)

### 7. Failure Diagnostics and the Retry Ladder

**Log the useful line.** ffmpeg writes its diagnostics to stderr in order, and the
last line is usually a generic `Terminating thread with return code ...`. The first
line is nearly always the one that explains the failure, so the log records the
first and last lines and keeps the complete stderr of every failed attempt in
`error_log_dir` (newest `error_log_max_files` retained).

**Retry before giving up.** A failed video encode is retried up to
`ffmpeg_retry_attempts` times, each rung targeting a different failure class:

| Rung | Change | Targets |
|------|--------|---------|
| 1 | as configured | — |
| 2 | normalise every frame onto a fixed canvas (`scale`/`pad` from the source's first video stream) and add `-reinit_filter 0` | sources whose parameters change mid-stream |
| 3 | rung 2 plus software decoding (drops `-hwaccel`, but **keeps** `-vaapi_device`) | decoder-side failures |
| 4 | rung 3 plus `-fflags +igndts+genpts` | sources with broken / non-monotonic timestamps |

Rung 3 disables hardware *decoding* only. It must not drop `-vaapi_device`: the
output chain still ends in `hwupload` and still encodes with `av1_vaapi`, and both
need the device reference that option provides. Stripping it too made every rung-3
and rung-4 attempt fail with `A hardware device reference is required to upload
frames to` — a new error in place of the one the rung was retrying. See
`../.probe/test_rung3_device.sh`.

The ladder is entered **either** when ffmpeg exits non-zero **or** when it exits 0
but produced an unusable file (missing, empty, or with a duration outside
`duration_tolerance`). The second case matters: a source with broken timestamps can
make an encoder stop early and still exit successfully, producing a truncated file.
Previously that was recorded as a terminal failure on the first attempt.

Audio-only remuxes copy the video stream and never decode it, so they cannot hit
these failures and are never retried.

**The ladder has an audio dimension too.** The video rungs never touch the audio
chain, so a source whose audio refuses the fold chain failed all four attempts
identically and was blacklisted — measured on Hijack S01E01/E04, whose E-AC-3
(Atmos/JOC) tracks change channel layout between frames. ffmpeg negotiates the
`pan` filter's input once and then aborts with *"Changing audio frame
properties on the fly is not supported"*. When a failed attempt carries that
signature, the remaining attempts step the audio strategy down:

| Audio strategy | What ffmpeg actually runs | Used after |
|----------------|---------------------------|------------|
| `fold`         | `-af "pan=stereo\|...,alimiter=..."` (the default) | first attempt |
| `native`       | no `-af`; `-ac 2 -ar 48000` downmix through the reconfigurable resampler | the fold chain failed with the audio-property signature |
| `prune`        | keep the chosen track, `-c:a copy` | `native` failed the same way |

The video rungs (fixed canvas, software decode, timestamp repair) still apply
alongside, so a file whose audio refuses every re-encode completes with the
selected track instead of being blacklisted. The post-transcode audio checks
are skipped for the pruned case, since a copied track is the source's own codec.

**Why rung 2 works.** A file that changes resolution part-way through — common in
"assembled" releases, e.g. a WEB-DL with a 1920x1080 logo sequence followed by a
1920x960 feature — makes ffmpeg try to rebuild its filter graph mid-encode. With a
hardware encoder that rebuild fails, and ffmpeg exits with `-38` (`Function not
implemented`, surfaced as exit status 218):

```
[vf#0:0] Reconfiguring filter graph because video parameters changed to yuv420p(unknown, bt709), 1920x960
[vf#0:0] Error reinitializing filters!
[vf#0:0] Task finished with error code: -38 (Function not implemented)
[vf#0:0] Terminating thread with return code -38 (Function not implemented)
```

Pinning the canvas with `scale=...:force_original_aspect_ratio=decrease` + `pad`
means the graph output never changes size, and `-reinit_filter 0` stops ffmpeg from
attempting the rebuild at all.

Use `--retry-failed` to give files that were already blacklisted as
`ffmpeg-crash-*` one pass through the ladder (a `.bak` copy of the skip file is kept).

## Logging and Monitoring

### Log Levels
- **ERROR** (Red): Critical failures, file processing errors
- **WARN** (Orange): Warnings, potential issues
- **SUCCESS** (Yellow): Successful operations
- **INFO** (Green): General information

### Process Monitoring
- Real-time size monitoring during transcoding
- FFmpeg `-progress` parsing for elapsed time and processed frames
- 10% early-abort when output size is already >= 10% of original at 10% playback
- Automatic timeout handling for stuck jobs
- Process priority management (nice level 15)
- Background process cleanup

## Error Handling

### Automatic Recovery
- Kills and restarts timed-out jobs
- Cleans up temporary files on failures
- Maintains error logs for troubleshooting
- Skips problematic files on subsequent runs

### Common Error Scenarios
- Output file larger than original
- Early abort at 10% because output is already proportionally too large
- Incorrect duration in transcoded file
- Missing video/audio streams
- Insufficient size reduction
- Transcoding timeout

## Testing Mode

Set `MOVE_FILE=0` to enable testing mode:
- Processes files normally
- Performs all validations
- Does not replace original files
- Outputs remain in `/dev/shm/ffmpeg-transcode/`

## Performance Optimization

### GPU Threading
- Configurable number of simultaneous GPU jobs
- Automatic process priority adjustment
- Memory-efficient temporary storage using `/dev/shm`

### Smart SHM Reservation
- Expected-output-size reservation frees up `/dev/shm` for more concurrent jobs
- Configurable safety margin and floor to balance risk vs. throughput
- Duration-based estimate avoids over-reserving for long, high-bitrate sources
- Capped at source size for safety when bitrate metadata is unreliable

### Queue Management
- Automatic queue restart to pick up new files
- Size-based processing order (largest first)
- Skip list optimization for faster subsequent runs
- Out-of-order dispatch: when the next video can't fit in SHM, a smaller video may jump the queue to keep the GPU busy

## Troubleshooting

### Common Issues

1. **VAAPI not available**
   - Ensure GPU drivers are installed
   - Check `/dev/dri/renderD128` exists
   - Verify FFmpeg has VAAPI support

2. **Files not being processed**
   - Check file age vs `MIN_VIDEO_AGE`
   - Verify file size vs `MIN_VIDEO_SIZE`
   - Check if codec is in skip list

3. **Transcoding failures**
   - Review `transcode.log` for error details
   - Check available disk space
   - Verify input file integrity

### Log Analysis

Monitor the log file for processing status:
```bash
tail -f transcode.log
```

Check skip lists to see what's being skipped:
```bash
grep -c "transcoded" skip.csv      # finished files
grep -v "transcoded" skip.csv    # terminal failures
```

## License

This script is provided as-is for video transcoding purposes. Modify and use according to your needs.