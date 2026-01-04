# FFmpeg Video Transcoding Script

A powerful bash script for hardware-accelerated video transcoding using FFmpeg with VAAPI and AV1 encoding. This script is designed for Linux systems and provides efficient batch processing of video files with advanced features like multi-threading, error handling, and automatic queue management.

## Features

### Core Functionality
- **Hardware-Accelerated Encoding**: Uses VAAPI (Video Acceleration API) for efficient AV1 encoding
- **Multi-Threading**: Configurable number of simultaneous GPU encoding jobs
- **Batch Processing**: Automatically scans directories and processes multiple video files
- **Smart Skip Lists**: Maintains lists of processed and errored files to avoid reprocessing

### Quality Control
- **Duration Validation**: Ensures transcoded files match original duration (±10 seconds tolerance)
- **Size Validation**: Configurable minimum/maximum file size reduction percentages
- **Codec Verification**: Validates video and audio streams in output files
- **Real-time Monitoring**: Monitors output file size during transcoding to prevent oversized outputs

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

Configuration is managed through the `transcode-config.json` file. Edit this file to customize the following settings:

### Main Settings

```json
{
  "MEDIA_PATH": "/var/mnt/videos",        // Path to scan for videos
  "MIN_VIDEO_SIZE": 0,                    // Minimum size in MB before quitting
  "MIN_VIDEO_AGE": 0,                     // Minimum age of file to process (days)
  "GPU_THREADS": 2                        // Number of simultaneous GPU jobs
}
```

### Transcoding Parameters

```json
{
  "FFMPEG_TIMEOUT": 6000,                 // Timeout per job (minutes)
  "FFMPEG_MIN_DIFF": 10,                 // Minimum size reduction percentage
  "FFMPEG_MAX_DIFF": 99,                 // Maximum size reduction percentage
  "VIDEO_CODEC_SKIP_LIST": "av1",        // Codecs to skip (comma-separated)
  "MOVE_FILE": 1                         // 1=move files, 0=test mode
}
```

### Scan Behavior

```json
{
  "SCAN_AT_START": 1,                    // 0=background scan, 1=force scan, 2=no scan
  "RESTART_QUEUE": 720                   // Minutes before queue restart
}
```

## Usage

### Basic Usage

```bash
./transcode.sh
```

## File Structure

### Project Files

- `transcode-config.json` - Configuration file for all script settings
- `transcode.sh` - Main transcoding script

### Runtime Files (Generated During Execution)

- `transcode.log` - Main log file with timestamped entries (created during execution)
- `scan_results.csv` - CSV file with discovered video files and sizes (created during execution)
- `skip.txt` - List of successfully processed files (created during execution)
- `skiperror.txt` - List of files that encountered errors (created during execution)
- `/dev/shm/ffmpeg-transcode/` - Temporary processing directory (created during execution)

### Supported Video Formats

- `.mkv`
- `.avi` 
- `.ts`
- `.mov`
- `.y4m`
- `.m2ts`
- `.mp4`
- `.wmv`

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

### 4. Post-Processing Validation
- Verifies output file exists and has non-zero size
- Checks duration matches original (±10 seconds)
- Validates video and audio streams
- Confirms size reduction within configured limits
- Moves processed file to replace original (if enabled)

## Logging and Monitoring

### Log Levels
- **ERROR** (Red): Critical failures, file processing errors
- **WARN** (Orange): Warnings, potential issues
- **SUCCESS** (Yellow): Successful operations
- **INFO** (Green): General information

### Process Monitoring
- Real-time size monitoring during transcoding
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

### Queue Management
- Automatic queue restart to pick up new files
- Size-based processing order (largest first)
- Skip list optimization for faster subsequent runs

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
wc -l skip.txt skiperror.txt
```

## License

This script is provided as-is for video transcoding purposes. Modify and use according to your needs.