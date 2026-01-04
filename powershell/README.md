# FFmpeg Video Transcoding Script

A Windows PowerShell script to re-encode media library videos using FFmpeg with hardware acceleration. This script helps reduce storage consumption by efficiently transcoding video files.

## Features

- **Background Scanning**: Traverses media path and scans all video files in subfolders as a background job
- **Hardware Acceleration**: Supports GPU offload for faster transcoding
- **Smart Validation**: Runs various checks to ensure transcode was successful:
  - Duration/length verification
  - Video and audio stream validation
  - Minimum percentage change verification
- **Codec Skip List**: Checks if video codec is on the skip list before processing
- **Logging**: Writes to `transcode.log` for detailed operation tracking
- **Low Priority**: FFmpeg runs at low priority so you can continue using your system

## Requirements

- FFmpeg executables for Windows with GPU offload support
  - Download from: https://ffmpeg.org/download.html
  - Run `get-ffmpeg.ps1` to automatically download the latest FFmpeg version to the current directory
- PowerShell 5.1 or later
- Windows-compatible GPU for hardware acceleration

## Usage

1. Run `get-ffmpeg.ps1` to download FFmpeg binaries (if not already present)
2. Edit configuration settings in `transcode.ps1`:
   - Set your media path
   - Configure minimum file size and age
   - Adjust FFmpeg parameters
   - Set number of concurrent transcoding jobs
3. Run the transcoding script:
   ```powershell
   .\transcode.ps1
   ```

## Configuration

Configuration settings are located in `transcode.ps1`. Key settings include:

- **Media Path**: Directory to scan for video files
- **Minimum File Size**: Minimum size threshold for processing
- **Minimum File Age**: Minimum age of files to process
- **Move File**: Set to `1` to overwrite source files after successful transcoding (WARNING: this is the default!)
- **Codec Skip List**: List of video codecs to skip
- **Concurrent Jobs**: Number of simultaneous transcoding operations

## Warning

⚠️ **By default, the script will overwrite source files after successful transcoding. Make sure you have backups of your media files before running the script.**

## Project Structure

```
├── README.md                  # This file
├── get-ffmpeg.ps1            # FFmpeg download script
├── transcode.ps1             # Main transcoding script
└── include/                  # PowerShell modules and jobs
    ├── functions.psm1        # Common functions module
    ├── job_health_check.ps1  # Health check job script
    ├── job_media_scan.ps1    # Media scanning job script
    └── job_transcode.ps1     # Transcoding job script
```

## Logging

The script maintains detailed logs in `transcode.log` including:
- Scan results and discovered files
- Transcoding operations and status
- Errors and warnings
- Validation results

## Known Limitations

- Does not display real-time progress status during transcoding
- Requires manual configuration of FFmpeg path if not using the default location

## License

This script is provided as-is for video transcoding purposes. Modify and use according to your needs.
