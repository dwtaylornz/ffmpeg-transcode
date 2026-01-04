# FFmpeg Transcode

A cross-platform media transcoding automation tool that helps reduce storage consumption of your media library by efficiently re-encoding video files using FFmpeg. Available for both Linux (Bash) and Windows (PowerShell).

## Features

- Automated scanning and transcoding of media libraries
- Hardware-accelerated video encoding support
- Background scanning and parallel transcoding
- Configurable encoding parameters and quality settings
- Extensive error checking and validation
- Detailed logging of transcode operations
- Skip lists for already optimized files
- File age and size filtering

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
2. Edit the configuration in `transcode-config.json`:
   - Set your media path
   - Configure minimum video size and age
   - Adjust FFmpeg parameters
   - Set number of parallel transcoding threads
3. Run the script:
   ```bash
   ./transcode.sh
   ```

### Windows (PowerShell)
1. Navigate to the `powershell` directory
2. Run `get-ffmpeg.ps1` to download the latest FFmpeg binaries
3. Edit configuration settings in `transcode.ps1`
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
├── bash/                          # Linux implementation
│   ├── README.md                  # Linux-specific documentation
│   ├── transcode-config.json      # Configuration file
│   └── transcode.sh               # Main bash script
└── powershell/                    # Windows implementation
    ├── README.md                  # Windows-specific documentation
    ├── get-ffmpeg.ps1            # FFmpeg download script
    ├── transcode.ps1             # Main PowerShell script
    └── include/                  # PowerShell modules and jobs
        ├── functions.psm1        # Common functions module
        ├── job_health_check.ps1  # Health check job script
        ├── job_media_scan.ps1    # Media scanning job script
        └── job_transcode.ps1     # Transcoding job script
```

## Logging and Monitoring

Both implementations maintain detailed logs and tracking:
- Operation logs for transcode activities
- Error logs for failed transcodes
- Progress tracking for ongoing operations

For more detailed information about each platform's implementation, see the platform-specific README files in the `bash/` and `powershell/` directories.

## Contributing

Feel free to submit issues and pull requests to help improve the scripts.

## License

This project is open source. Please check the repository's license file for details.
