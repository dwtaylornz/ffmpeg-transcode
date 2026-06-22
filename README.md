# FFmpeg Transcode

A cross-platform media transcoding automation tool that helps reduce storage consumption of your media library by efficiently re-encoding video files using FFmpeg. Available for both Linux (Bash) and Windows (PowerShell).

## Features

- Automated scanning and transcoding of media libraries
- Hardware-accelerated video encoding support (VAAPI on Linux, GPU offload on Windows)
- Background scanning and parallel transcoding with configurable job counts
- Multiple media path configurations (Linux)
- Automatic GPU utilization monitoring and dynamic thread ramping (Linux)
- Configurable encoding parameters and quality settings
- Extensive error checking and validation (duration, size, codec, stream)
- **Early size-efficiency abort at 25% playback (Linux)** — stops a transcode early if the output is already larger than 25% of the original file size at 25% of the playback time, avoiding wasted encoding time on files that will not shrink enough
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

### Linux 25% Early-Abort Details

The Linux script (`bash/transcode.sh`) now parses FFmpeg `-progress` output in real time. While a transcode is running, the monitor compares the encoded output size to the original file size. As soon as the encode reaches **25% of the original playback time** and the output has already reached **25% of the original file size**, it assumes the final encode is unlikely to be smaller than the source and aborts the transcode early. This saves the time that would otherwise be spent encoding the remaining 75% of a file that will not yield useful space savings.

Behavior on early abort:
- FFmpeg is sent `SIGTERM` and given a short grace period to shut down cleanly.
- The partial output and temporary files are removed automatically.
- The source file is left untouched.
- The file is recorded in `skiperror.txt` with reason `early-abort-size-inefficient`, so it is skipped on future runs.
- A warning is written to `transcode.log` showing the size and elapsed time that triggered the abort.

Files already handled by the post-transcode size check (output larger than original at completion) are still caught as before; the 25% check adds a midpoint guard for long encodes.

For more detailed information about each platform's implementation, see the platform-specific README files in the `bash/` and `powershell/` directories.

## Contributing

Feel free to submit issues and pull requests to help improve the scripts.

## License

This project is open source. Please check the repository's license file for details.
