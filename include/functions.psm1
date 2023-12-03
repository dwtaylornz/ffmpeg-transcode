
function Get-VideoCodec ([string] $video_path) {
    #Write-Host "Check if file is HEVC first..."
    $video_codec = $null
    $video_codec = (.\ffprobe.exe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`")
    if (Select-String -pattern "hevc" -InputObject $video_codec -quiet) { $video_codec = "hevc" }
    if (Select-String -pattern "h264" -InputObject $video_codec -quiet) { $video_codec = "h264" } 
    if (Select-String -pattern "vc1" -InputObject $video_codec -quiet) { $video_codec = "vc1" }          
    if (Select-String -pattern "mpeg2video" -InputObject $video_codec -quiet) { $video_codec = "mpeg2video" }
    if (Select-String -pattern "mpeg4" -InputObject $video_codec -quiet) { $video_codec = "mpeg4" }
    if (Select-String -pattern "rawvideo" -InputObject $video_codec -quiet) { $video_codec = "rawvideo" }
    if (Select-String -pattern "vp9" -InputObject $video_codec -quiet) { $video_codec = "vp9" }
    return $video_codec
}

function Get-AudioCodec ([string] $video_path) {
    $audio_codec = $null
    $audio_codec = .\ffprobe.exe -v quiet -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`"
    # if (Select-String -pattern "dts" -InputObject $audio_codec -quiet) { $audio_codec = "dts" }
    return $audio_codec
}

function Get-AudioChannels ([string] $video_path) {
    $audio_channels = $null
    $audio_channels = .\ffprobe.exe -v quiet -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`"
    return $audio_channels
}

function Get-VideoWidth ([string] $video_path) {
    #check video width (1920 width is more consistant for 1080p videos)
    $video_width = $null 
    $video_width = (.\ffprobe.exe -loglevel quiet -show_entries stream=width -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String
    if (Select-String -pattern "N/A" -InputObject $video_width -quiet) { $video_width = (.\ffprobe.exe -v quiet -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1  "`"$video_path"`") | Out-String }   
    $video_width = $video_width.trim()
    $video_width = $video_width.Split("")[0]
    if (Select-String -pattern "1920" -InputObject $video_width -quiet) { $video_width = "1920" }   
    try {  $video_width = [Int]$video_width }
    catch { write-host "  "$video.name" width issue"}
    return $video_width
}

function Get-VideoDuration ([string] $video_path) {
    $video_duration = $null 
    $video_duration = (.\ffprobe.exe -loglevel quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$video_path"`") | Out-String
    $video_duration = $video_duration.trim()
    try { $video_duration = [int]$video_duration }
    catch { write-host "  "$video.name" duation issue"}
    return $video_duration
}

function Get-VideoDurationFormatted ([string] $video_duration) {
    # not getting remainding seconds (as sometimes movie is shortened by a couple)
    $video_duration_formated = $null
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
    $skiptotal_count = $skipped_files.Count + $skippederror_files.Count + $skippedhevc_files.Count
    Write-Host "Previously processed files: $($skipped_files.Count)" 
    Write-Host "Previously errored files: $($skippederror_files.Count)" 
    Write-Host "Existing HEVC files: $($skippedhevc_files.Count)" 
    Write-Host ""    
    Write-Host "Total files to skip: $skiptotal_count"
    Write-Host ""
    Write-Host -NoNewLine "Settings - " 
    Write-Host -NoNewline "Encoding: "
    Write-Host -NoNewLine -ForegroundColor Green "$ffmpeg_codec"
    if ($ffmpeg_hwdec -eq 0) {
        Write-Host -NoNewline " Decoding: "
        Write-Host -noNewLine -ForegroundColor Green "CPU"
    }
    if ($ffmpeg_hwdec -eq 1) {
        Write-Host -NoNewline " GPU Decoding: "
        Write-Host -noNewLine -ForegroundColor Green "GPU"
    }
    Write-Host ""    
    Write-Host ""   
         
    if ((get-job -State Running -ea silentlycontinue) ) {
        Write-Host "Currently Running Jobs - "
        get-job -State Running 
        Write-Host ""
    }
}
function Initialize-Folders() {
    # Setup required folders
    if (!(test-path -PathType container output)) { new-item -itemtype directory -force -path output | Out-Null }
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

# File stuff 
function Get-Videos() {
    # get-job -State Completed | Remove-Job
    get-job -Name Scan -ea silentlycontinue | Stop-Job -ea silentlycontinue | Out-Null  
    if (-not(test-path -PathType leaf $log_path\scan_results.csv) -or $scan_at_start -eq 1) { 
        Write-Host  -NoNewline "Running file scan... " 
        Start-Job -Name "Scan" -FilePath .\include\job_media_scan.ps1 -ArgumentList $RootDir | Out-Null
        Receive-Job -name "Scan" -wait -Force
        Start-Sleep 2 
        $videos = @(Import-Csv -Path $log_path\scan_results.csv -Encoding utf8)
        Write-Host " files: " $videos.Count
    }  
    elseif ($scan_at_start -eq 0) {
        
        Write-Host -NoNewline "Getting previous scan results & running new scan in background: " 
        $videos = @(Import-Csv -Path $log_path\scan_results.csv -Encoding utf8)
        Write-Host $videos.Count
        Start-Job -Name "Scan" -FilePath .\include\job_media_scan.ps1 -ArgumentList $RootDir | Out-Null 
    }
    elseif ($scan_at_start -eq 2) {
    
        Write-Host -NoNewline "Getting previous scan results: " 
        $videos = @(Import-Csv -Path $log_path\scan_results.csv -Encoding utf8)
        Write-Host $videos.Count
    }
    return $videos
}
function Get-Skip() {
    $skipped_files = $null
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
    $skippederror_files = $null
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

function Get-ColorFixed() {
    $colorfixed_files = $null
    if ((test-path -PathType leaf $log_path\skipcolorfixed.txt)) { 
        $mutexName = 'Get-ColorFixed'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            $colorfixed_files = @(Get-Content -Path $log_path\skipcolorfixed.txt -Encoding utf8 -ErrorAction Stop) 
        }
        finally {
            $mutex.ReleaseMutex()
        }      
    }
    return $colorfixed_files
}


function Get-SkipHEVC() {
    $skippedhevc_files = $null
    if ((test-path -PathType leaf $log_path\skiphevc.txt)) { 
        $mutexName = 'Get-SkipHEVC'
        $mutex = New-Object 'Threading.Mutex' $false, $mutexName
        $check = $mutex.WaitOne() 
        try {
            $skippedhevc_files = @(Get-Content -Path $log_path\skiphevc.txt -Encoding utf8 -ErrorAction Stop)     
        }
        finally {
            $mutex.ReleaseMutex()
        }        
    }
    return  $skippedhevc_files
}
function Write-Log  ([string] $LogString) {
    if ($LogString) {
        $Logfile = "$log_path\hevc_transcode.log"
        $Stamp = (Get-Date).toString("yy/MM/dd HH:mm:ss")
        $LogMessage = "$Stamp $env:computername$LogString"
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

function Write-ColorFixed ([string] $video_name) {
    if ($video_name) { 
        $Logfile = "$log_path\skipcolorfixed.txt"
        $mutexName = 'Write-ColorFixed'
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

function Write-SkipHEVC ([string] $video_name) {
    if ($video_name) { 
        $Logfile = "$log_path\skiphevc.txt"
        $mutexName = 'Write-SkipHEVC'
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

Export-ModuleMember -Function *
