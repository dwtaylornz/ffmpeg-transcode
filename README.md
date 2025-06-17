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
2. Edit the configuration parameters in `transcode.sh`:
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
3. Edit settings in `variables.ps1`
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
├── bash/               # Linux implementation
│   ├── transcode.sh    # Main bash script
│   ├── scan_results.csv
│   ├── skip.txt       # Skip list for processed files
│   └── transcode.log  # Operation logs
└── powershell/        # Windows implementation
    ├── get-ffmpeg.ps1 # FFmpeg download script
    ├── transcode.ps1  # Main PowerShell script
    ├── variables.ps1  # Configuration file
    └── include/       # PowerShell modules and jobs
```

## Logging and Monitoring

Both implementations maintain detailed logs:
- Transaction logs in `transcode.log`
- Skip lists for processed files
- Error logs for failed transcodes

## Contributing

Feel free to submit issues and pull requests to help improve the scripts.

## License

This project is open source. Please check the repository's license file for details.
