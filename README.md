# FFmpeg Transcode

A cross-platform media transcoding automation tool that helps reduce storage consumption of your media library by efficiently re-encoding video files using FFmpeg. Available for both Linux (Bash) and Windows (PowerShell).

## Features

- Automated scanning and transcoding of media libraries
- Hardware-accelerated video encoding support (VAAPI on Linux, GPU offload on Windows)
- Background scanning and parallel transcoding with configurable job counts
- Multiple media path configurations (Linux)
- Automatic GPU utilization monitoring and dynamic thread ramping (Linux)
- **Smart SHM reservation (Linux)** — estimates `/dev/shm` space per job from expected output size (`duration × target bitrate`) instead of reserving the full source size, enabling much higher concurrency and better GPU utilization
- Configurable encoding parameters and quality settings
- Extensive error checking and validation (duration, size, codec, stream)
- **Early size-efficiency abort at 10% playback (Linux)** — stops a transcode early if the output is already larger than 10% of the original file size at 10% of the playback time, avoiding wasted encoding time on files that will not shrink enough
- **Audio re-encoding to Opus stereo (Linux)** — keeps one preferred-language audio track and re-encodes it to stereo Opus (`libopus`, 128 k) in the same ffmpeg pass as the video, dropping duplicate language tracks and lossless/high-bitrate audio that a stereo playback setup cannot use. The downmix folds centre, surrounds and LFE into the stereo pair, so a 2.1 soundbar still receives its bass. Containers that cannot carry Opus (e.g. MP4 output) fall back to AC-3 at `audio_fallback_bitrate`. Files whose video is already AV1 can be fixed by an audio-only remux that copies the video stream and needs no GPU
- **Dry-run mode (Linux)** — `--dry-run` prints the exact ffmpeg command for each file that would be processed, without running ffmpeg or modifying anything
- Detailed logging of transcode operations
- Persistent skip lists for already optimized and errored files
- File age and size filtering
- Timeout handling for stuck transcoding jobs

## Requirements

### Linux (Bash)
- FFmpeg with hardware acceleration support
- Bash shell
- A compatible GPU for hardware acceleration (configured for VAAPI)

### Windows (PowerShell)
- FFmpeg executables for Windows
- PowerShell
- Windows-compatible GPU for hardware acceleration

## Getting Started

### Linux (Bash)
1. Navigate to the `bash` directory
2. Copy the example configuration and edit it:
   ```bash
   cp transcode-config.json.example transcode-config.json
   ```
3. Edit the configuration in `transcode-config.json`:
   - Set your media paths under `configurations`
   - Configure minimum video size and age
   - Adjust FFmpeg output parameters
   - Set minimum/maximum GPU threads and GPU utilization target
4. Run the script:
   ```bash
   ./transcode.sh
   ```

### Windows (PowerShell)
1. Navigate to the `powershell` directory
2. Run `get-ffmpeg.ps1` to download the latest FFmpeg binaries
3. Create and edit configuration settings in `variables.ps1` (use `transcode.ps1` as a reference)
4. Run the transcoding script:
   ```powershell
   .\transcode.ps1
   ```

## Configuration

### Common Settings
- Media path location
- Minimum file size to process
- Minimum file age
- Encoding parameters
- Number of concurrent transcoding jobs

## Warning

**⚠️ By default, both scripts will overwrite source files after successful transcoding. Make sure you have backups of your media files before running the scripts.**

## Project Structure

```
├── bash/                                           # Linux implementation
│   ├── README.md                                   # Linux-specific documentation
│   ├── transcode-config.json.example               # Example configuration file
│   └── transcode.sh                                # Main bash script
├── powershell/                                     # Windows implementation
│   ├── README.md                                   # Windows-specific documentation
│   ├── get-ffmpeg.ps1                              # FFmpeg download script
│   ├── transcode.ps1                               # Main PowerShell script and configuration
│   └── include/                                    # PowerShell modules and jobs
│       ├── functions.psm1                          # Common functions module
│       ├── job_health_check.ps1                    # Health check job script
│       ├── job_media_scan.ps1                      # Media scanning job script
│       └── job_transcode.ps1                       # Transcoding job script
├── .gitignore                                      # Git ignore rules
└── README.md                                       # This file
```

## Logging and Monitoring

Both implementations maintain detailed logs and tracking:
- Operation logs for transcode activities
- Error logs for failed transcodes
- Progress tracking for ongoing operations

### Linux Smart SHM Reservation Details

The Linux script (`bash/transcode.sh`) now reserves `/dev/shm` space based on **expected output size** rather than the full source file size. Previously, a 10 GB source file would reserve 10 GB of shared memory, severely capping concurrent transcodes and starving the GPU.

Instead, `calc_reserve()` computes:
\[
\text{reserve\_mb} = \frac{\text{duration(s)} \times \text{target\_bitrate(Mbps)}}{8} \times \text{safety\_pct}
\]

- **Target bitrate** is extracted from `ffmpeg_output_params` via `parse_bv()`: prefers `-maxrate` (peak) for a safe upper bound, falls back to `-b:v` (average), defaults to 5 Mbps.
- **Safety margin** is configurable via `shm_reserve_safety_pct` (default 130%) to account for muxing overhead.
- **Floor** is configurable via `shm_reserve_floor_mb` (default 200 MB) for very short files.
- The reservation is **capped at the source file size** (for cases where bitrate exceeds source bitrate).
- When duration is unavailable (e.g., corrupt headers), the script falls back to the conservative source-size approach.

This change directly improves GPU utilization: the GPU is no longer idle waiting for `/dev/shm` to free up, because many more concurrent jobs can fit in the same memory budget.

### Linux 10% Early-Abort Details

The Linux script (`bash/transcode.sh`) now parses FFmpeg `-progress` output in real time. While a transcode is running, the monitor compares the encoded output size to the original file size. As soon as the encode reaches **10% of the original playback time** and the output has already reached **10% of the original file size**, it assumes the final encode is unlikely to be smaller than the source and aborts the transcode early. This saves the time that would otherwise be spent encoding the remaining 90% of a file that will not yield useful space savings.

Behavior on early abort:
- FFmpeg is sent `SIGTERM` and given a short grace period to shut down cleanly.
- The partial output and temporary files are removed automatically.
- The source file is left untouched.
- The file is recorded in `skip.csv` with reason `early-abort-size-inefficient`, so it is skipped on future runs.
- A warning is written to `transcode.log` showing the size and elapsed time that triggered the abort.

Files already handled by the post-transcode size check (output larger than original at completion) are still caught as before; the 10% check adds an earlier guard for long encodes.

For more detailed information about each platform's implementation, see the platform-specific README files in the `bash/` and `powershell/` directories.

### Configuration — New Global Settings (Linux)

| Key | Default | Description |
|-----|---------|-------------|
| `shm_reserve_safety_pct` | `130` | Safety margin percentage applied to the expected output size when reserving `/dev/shm` space |
| `shm_reserve_floor_mb` | `200` | Minimum `/dev/shm` reservation per job (MB), ensuring very short files get a reasonable allocation |

### Configuration — Audio Settings (Linux)

| Key | Default | Description |
|-----|---------|-------------|
| `audio_codec` | `opus` | Target **stream** codec name (what ffprobe reports back). Also used by the post-transcode verification check |
| `audio_encoder` | *(follows `audio_codec`)* | libavcodec encoder passed to `-c:a`. Set to `libopus` for the Opus encoder; the keys are separate because some encoders (e.g. `libfdk_aac`) produce a stream whose codec name differs from the encoder requested |
| `audio_vbr` | `0` | `1`-`5` selects libfdk_aac VBR mode only; `0` = CBR at `audio_bitrate` |
| `audio_bitrate` | `128k` | Target bitrate for the CBR path; not passed to ffmpeg while `audio_vbr` is `1`-`5`. Can be overridden per configuration |
| `audio_containers` | `mkv,webm` | Output containers that carry the primary codec (Opus); anything else gets the fallback below |
| `audio_fallback_codec` | `ac3` | Codec used when the output container cannot carry Opus (e.g. MP4) |
| `audio_fallback_bitrate` | `224k` | Bitrate for the fallback codec |
| `audio_channels` | `2` | Target channel count (stereo downmix) |
| `audio_sample_rate` | `48000` | Output sample rate |
| `audio_max_tracks` | `1` | Maximum audio tracks to keep; can be overridden per configuration |
| `audio_min_bitrate_kbps` | `448` | Re-encode even a ≤2ch track above this bitrate |
| `audio_preferred_languages` | `eng,en` | Track selection preference order (outranks the container's `default` flag) |
| `audio_always_reencode_codecs` | `truehd,mlp,dts,flac,wavpack,alac,pcm_*` | Codecs always re-encoded regardless of bitrate |
| `audio_lfe_fold` | `1` | `1` folds centre, surrounds and LFE into the stereo pair via `pan`. `0` uses ffmpeg's own downmix, which discards LFE entirely and attenuates the mix by its coefficient sum (measured −91 dB and −7.7 dB respectively on 5.1) |
| `audio_limiter` | `1` | `1` appends `alimiter` after the fold, replacing the clipping guard that ffmpeg's own downmix normalisation provides |
| `audio_limiter_limit` | `0.95` | Limiter ceiling (linear) |
| `audio_max_jobs` | `3` | Maximum concurrent audio-only remux jobs |
| `audio_catchup` | `1` | Also fix files whose video is already in `video_codec_skip_list` |
| `ffmpeg_retry_attempts` | `4` | Retry ladder for video encodes (1 = no retry). Rung 2 pins a fixed canvas and disables filter-graph reinitialisation; rung 3 also drops hardware decoding (but keeps `-vaapi_device`, which the hardware encoder and `hwupload` still need); rung 4 adds `-fflags +igndts+genpts` for broken timestamps. Also entered when ffmpeg exits 0 but produced an unusable (truncated/empty) file. A failed audio fold chain (sources that change audio format mid-stream, e.g. E-AC-3 Atmos) additionally degrades: plain `-ac`/`-ar` downmix, then copy the chosen track |
| `error_log_dir` | `./transcode-errors` | Full ffmpeg stderr kept for each failed attempt |
| `error_log_max_files` | `200` | Keep only the most recent N error logs |
| `lock_file` | `./transcode.lock` | Single-instance lock; only one real run at a time |

Audio output options in `ffmpeg_output_params` (e.g. `-c:a copy`) are stripped and
replaced by the script's own audio arguments.

### Command-line options (Linux)

| Option | Purpose |
|--------|---------|
| `--config PATH` | Use a specific configuration file |
| `--dry-run`, `-n` | Print the ffmpeg command for each file that would be processed; touch nothing |
| `--limit N` | Process at most N files, then drain and stop (with `--dry-run`, preview N instead) |
| `--max-size-mb N` | Only process files up to N MB — combined with `--limit`, a fast smoke test on small real files |
| `--audio-only` | Never re-encode video: every file becomes an audio-only remux. No GPU needed, so it does not compete with the encoders |
| `--retry-failed` | Re-queue files that previously crashed or were aborted early, so they get another pass with the current retry ladder and progress logic |

### Known failure mode: exit 218 / "Function not implemented"

Files that change video parameters part-way through (a 1920x1080 logo sequence
followed by a 1920x960 feature, for example — common in assembled multi-language
releases) make ffmpeg rebuild its filter graph mid-encode. With a hardware encoder
that rebuild fails and ffmpeg exits with the error code for `-ENOSYS`, which the
shell reports as status 218:

```
[vf#0:0] Reconfiguring filter graph because video parameters changed to yuv420p(unknown, bt709), 1920x960
[vf#0:0] Terminating thread with return code -38 (Function not implemented)
```

The script previously recorded only the final "Terminating thread" line, which is
why this looked inexplicable, and treated the file as permanently failed. It now
records the first (useful) line, keeps the full stderr under `error_log_dir`, and
retries the encode with a fixed canvas and `-reinit_filter 0`, which prevents the
graph rebuild entirely. `--retry-failed` re-queues files that were blacklisted
before this existed.

### Audio re-encoding: what to expect

**`skip.csv` format change.** Before format 2 the skip file recorded only a video
outcome, and audio was copied verbatim — which is how a 46-minute episode could end
up carrying 22 full-bitrate language tracks. On first run the script migrates the
file: terminal errors are kept, video-only outcomes are dropped so those files are
re-probed and fixed by an audio-only remux where needed. Entries are now keyed by
full path instead of file name (legacy basename entries are still honoured).

**Two job modes.** Files that still need video work get the audio done in the same
pass (no extra I/O, ~1 CPU core for the duration of the audio). Files whose video is
already AV1 get an audio-only remux: the video stream is copied, no GPU device is
needed, the output is staged next to the source and atomically renamed over it, and
concurrency is capped by `audio_max_jobs`.

**Verify before trusting it.** Run `./transcode.sh --dry-run --limit 20` first; it
prints the exact ffmpeg command and the audio decision for each file without
modifying anything.

## Contributing

Feel free to submit issues and pull requests to help improve the scripts.

## License

This project is open source. Please check the repository's license file for details.
