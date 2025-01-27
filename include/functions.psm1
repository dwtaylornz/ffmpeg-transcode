function Get-VideoCodec ([string] $video_path) {
    try {
        $video_codec = (.\ffprobe.exe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`")
    }
    catch {
        return $null
    }
    $codec_patterns = "hevc", "h264", "vc1", "mpeg2video", "mpeg4", "rawvideo", "vp9", "av1"
    foreach ($pattern in $codec_patterns) {
        if (Select-String -pattern $pattern -InputObject $video_codec -quiet) { 
            return $pattern
        }
    }
    return $video_codec
}
function Get-AudioCodec ([string] $video_path) {
    try {
        return .\ffprobe.exe -v quiet -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`"
    }
    catch {
        return $null
    }
}
function Get-AudioChannels ([string] $video_path) {
    try {
        return .\ffprobe.exe -v quiet -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`"
    }
    catch {
        return $null
    }
}
function Get-VideoWidth ([string] $video_path) {
    try {
        $video_width = (.\ffprobe.exe -loglevel quiet -show_entries stream=width -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String
        if ($video_width -eq "N/A") { 
            $video_width = (.\ffprobe.exe -v quiet -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String 
        }   
        return [Int]$video_width.trim().Split("")[0]
    }
    catch {
        return $null
    }
}
function Get-VideoHeight ([string] $video_path) {
    try {
        $video_height = (.\ffprobe.exe -loglevel quiet -show_entries stream=height -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String
        if ($video_height -eq "N/A") { 
            $video_height = (.\ffprobe.exe -v quiet -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String 
        }   
        return [Int]$video_height.trim().Split("")[0]
    }
    catch {
        return $null
    }
}
function Get-VideoDuration ([string] $video_path) {
    try {
        $video_duration = (.\ffprobe.exe -loglevel quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`") | Out-String
        return [int]$video_duration.trim()
    }
    catch {
        return $null
    }
}
function Get-VideoDebugInfo () {
    Write-Host "Debug Info for $video_name"
    Write-Host "  output_path: $output_path"
    Write-Host "  video_new: $video_new"
    if ($video_new_name) { 
        Remove-Item "output\$video_new_name" -force -ea silentlycontinue 
    }
    Write-SkipError "$video_name"
}
function Get-VideoDurationFormatted ([string] $video_duration) {
    $video_duration_formated = [timespan]::fromseconds($video_duration)
    return ("{0:hh\:mm}" -f $video_duration_formated)    
}
function Get-JobStatus ([string] $job) {
    if ( [bool](get-job -Name $job -ea silentlycontinue) ) {
        return (get-job -Name $job).State 
    }
}
function Start-Delay {
    Write-Host -NoNewline "  Waiting 5 seconds before file move "
    Write-Host "(do not break or close window)" -ForegroundColor Yellow     
    Start-Sleep 5
}
function Show-State() {
    $skiptotal_count = $skipped_files.Count + $skippederror_files.Count 
    Write-Host "Previously processed files: $($skipped_files.Count)" 
    Write-Host "Previously errored files: $($skippederror_files.Count)" 
    Write-Host "`nTotal files to skip: $skiptotal_count`n"
    
    $decoding = if ($ffmpeg_hwdec -eq 0) { "CPU" } else { "GPU" }
    Write-Host "Settings - Encoding: $ffmpeg_video_codec Decoding: $decoding`n"

    if ((get-job -State Running -ea silentlycontinue)) {
        Write-Host "Currently Running Jobs - "
        get-job -State Running 
        Write-Host ""
    }
}
function Initialize-OutputFolder {
    $outputPath = "output"
    if (-not (Test-Path -Path $outputPath -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    }
    else {
        Get-ChildItem -Path $outputPath -Recurse | Remove-Item -Force -Recurse
    }
}
function Get-VideoAge ([string] $video_path) {
    try {
        $video_age = (Get-Date) - (Get-Item $video_path).CreationTime
        return $video_age.Days
    }
    catch {
        return 0
    }
}
function Invoke-HealthCheck() {
    if ($run_health_check -eq 1) { 
        Write-Host "Running health scan..." 
        Start-Job -Name "HealthCheck" -FilePath .\include\job_health_check.ps1 -ArgumentList $RootDir, $videos | Out-Null
    }
}

function Set-FFmpegLowPriority {
    try {
        $ffmpegProcesses = Get-Process ffmpeg -ErrorAction SilentlyContinue | Where-Object { $_.PriorityClass -ne 'BelowNormal' }
        if ($ffmpegProcesses) {
            foreach ($process in $ffmpegProcesses) {
                $process.PriorityClass = "BelowNormal" 
            }
        }
    }
    catch {
        # Silently continue if any errors occur
    }
}
function Get-Videos() {
    get-job -Name Scan -ea silentlycontinue | Stop-Job -ea silentlycontinue | Out-Null  
    $fileContent = Get-Content -Path "$log_path\scan_results.csv" -Raw -ErrorAction SilentlyContinue
    if (-not(Test-Path -PathType Leaf "$log_path\scan_results.csv") -or $scan_at_start -eq 1 -or [string]::IsNullOrEmpty($fileContent)) { 
        Write-Host -NoNewline "Running file scan... " 
        Start-Job -Name "Scan" -FilePath .\include\job_media_scan.ps1 -ArgumentList $RootDir | Out-Null
        Receive-Job -name "Scan" -wait -Force
        Start-Sleep 2 
    }
    $videos = @(Import-Csv -Path $log_path\scan_results.csv -Encoding utf8)
    Write-Host " files: " $videos.Count
    if ($scan_at_start -eq 0) {
        Write-Host "Getting previous scan results & running new scan in background" 
        Start-Job -Name "Scan" -FilePath .\include\job_media_scan.ps1 -ArgumentList $RootDir | Out-Null 
    }
    elseif ($scan_at_start -eq 2) {
        Write-Host "Getting previous scan results" 
    }
    return $videos
}
function Get-Skip() {
    if ((test-path -PathType leaf $log_path\skip.txt)) { 
        $mutexName = 'Get-Skip'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            return @(Get-Content -Path $log_path\skip.txt -Encoding utf8 -ErrorAction Stop) 
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
}
function Get-SkipError() {
    if ((test-path -PathType leaf $log_path\skiperror.txt)) { 
        $mutexName = 'Get-SkipError'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            return @(Get-Content -Path $log_path\skiperror.txt -Encoding utf8 -ErrorAction Stop) 
        }
        finally {
            $mutex.ReleaseMutex()
        }      
    }
}
function Write-Log  ([string] $LogString) {
    if ($LogString) {
        $Logfile = "$log_path\transcode.log"
        $Stamp = (Get-Date).toString("yy/MM/dd HH:mm:ss")
        $LogMessage = "$Stamp $env:computername $LogString"
        if ($LogString -like '*transcoding*') { Write-Host "$LogMessage" -ForegroundColor Cyan }
        elseif ($LogString -like '*ERROR*') { Write-Host "$LogMessage" -ForegroundColor Red }
        elseif ($LogString -like '*Saved:*') { Write-Host "$LogMessage" -ForegroundColor Green }
        else { Write-Host "$LogMessage" }
        $mutexName = 'Write-Log'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            Add-content $LogFile -value $LogMessage -Encoding utf8 -ErrorAction Stop     
        }
        finally {
            $mutex.ReleaseMutex()
        }       
    }
}
function Write-Skip ([string] $video_name) {
    if ($video_name) { 
        $Logfile = "$log_path\skip.txt"
        $mutexName = 'Write-Skip'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            Add-content $LogFile -value $video_name -Encoding utf8 -ErrorAction Stop
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
}
function Write-SkipError ([string] $video_name) {
    if ($video_name) { 
        $Logfile = "$log_path\skiperror.txt"
        $mutexName = 'Write-SkipError'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            Add-content $LogFile -value $video_name -Encoding utf8 -ErrorAction Stop
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
}
Export-ModuleMember -Function *
