## Reduce your media disk consumption with AV1!
A windows powershell script to re-encode media library videos using ffmpeg on windows. 

### requirements
- ffmpeg executables for windows (includes gpu offload) - https://ffmpeg.org/download.html

### usage 
- Download and place ffmpeg tools in same folder as script (windows - reccommend full gpl nightly build. https://github.com/BtbN/FFmpeg-Builds/releases) 
- Update variables.ps1 with your settings
- Run transcode.ps1 in powershell 

### warning! 
**Script will overwrite existing source files if conversion is successfull**

### functions
- traverses root path (scans all video files in subfolders) - as a job in background 
- overwrites source with new transcode if **move_file = 1** (WARNING this is default!) 
- checks to see if video codec is on skip list
- runs various checks that transcode was successful (length, file has video and audio stream, must be more than min % change)
- writes **av1_transcode.log** for logging 

### limitations (potential todo list) 
Deminishing effort vs reward - 
- does not have a progress status during transcode 
