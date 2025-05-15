# Description: This module contains functions for video processing, logging, and system checks.
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
    # not getting remaining seconds (as sometimes movie is shortened by a couple)
    $video_duration_formated = [timespan]::fromseconds($video_duration)
    $video_duration_formated = ("{0:hh\:mm}" -f $video_duration_formated)    
    return $video_duration_formated
}
function Get-JobStatus ([string] $job) {
    if ( [bool](get-job -Name $job -ea silentlycontinue) ) {
        $state = (get-job -Name $job).State 
        return $state
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
    Write-Host "Settings - Min Age: $min_video_age, Min Size: $min_video_size, Threads: $GPU_threads, Timeout: $ffmpeg_timeout, Restart Queue: $restart_queue"
    Write-Host "           FFMpeg Parrameters: $ffmpeg_parameters"
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
function Invoke-ColorFix() {
    if ($mkv_color_fix -eq 1) { 
        Write-Host "Fixing color on mkv files..." 
        Start-Job -Name "ColorFix" -FilePath .\include\job_color_fix.ps1 -ArgumentList $RootDir, $videos | Out-Null
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
    

    if ($scan_at_start -eq 0) {
        Write-Host "Getting previous scan results & running new scan in background" 
        Start-Job -Name "Scan" -FilePath .\include\job_media_scan.ps1 -ArgumentList $RootDir | Out-Null 
    }
    elseif ($scan_at_start -eq 2) {
        Write-Host "Getting previous scan results" 
    }

    Write-Host "File Count:" $videos.Count

    return $videos
}

function Get-Skip() {
    if ((test-path -PathType leaf $log_path\skip.txt)) { 
        $mutexName = 'Get-Skip'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            $skipped_files = @(Get-Content -Path $log_path\skip.txt -Encoding utf8 -ErrorAction Stop) 
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
    return $skipped_files
}
function Get-SkipError() {
    if ((test-path -PathType leaf $log_path\skiperror.txt)) { 
        $mutexName = 'Get-SkipError'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            $skippederror_files = @(Get-Content -Path $log_path\skiperror.txt -Encoding utf8 -ErrorAction Stop) 
        }
        finally {
            $mutex.ReleaseMutex()
        }      
    }
    return $skippederror_files
}
function Write-Log  ([string] $LogString) {
    if ($LogString) {
        $Logfile = "$log_path\transcode.log"
        $Stamp = (Get-Date).toString("yy/MM/dd HH:mm:ss")
        $LogMessage = "$Stamp $env:computername $LogString"
        if ($LogString -like '*transcoding*') { Write-Host "$LogMessage" -ForegroundColor Cyan }
        elseif ($LogString -like '*ERROR*') { Write-Host "$LogMessage" -ForegroundColor Red }
        elseif ($LogString -like '*Saved:*') { Write-Host "$LogMessage" -ForegroundColor Green }
        elseif ($LogString -like '*Saved:*') { Write-Host "$LogMessage" -ForegroundColor Green }
        elseif ($LogString -like '*Converting HEVC to MP4 container*') { Write-Host "$LogMessage" -ForegroundColor DarkGreen }
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
            return 
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
            return 
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
}

function Get-MediaInfo ([string] $video_path) {
    $ffprobeOutput = & .\ffprobe.exe -v quiet -print_format json -show_streams -show_format "`"$video_path`"" | Out-String | ConvertFrom-Json

    $videoStream = $ffprobeOutput.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $audioStream = $ffprobeOutput.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
    $format = $ffprobeOutput.format

    $mediaInfo = @{
        VideoCodec    = $videoStream.codec_name
        AudioCodec    = $audioStream.codec_name
        AudioChannels = $audioStream.channels
        VideoWidth    = $videoStream.width
        VideoHeight   = $videoStream.height
        VideoDuration = [int]([math]::Round([double]$format.duration,0))
    }
    return $mediaInfo
}

Export-ModuleMember -Function *