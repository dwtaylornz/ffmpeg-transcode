#!/usr/bin/env powershell
# github.com/dwtaylornz/hevctranscode
#
# script will loop through largest to smallest videos transcoding to HEVC
# populate variables.ps1 before running this script. 

Set-Location $PSScriptRoot
$RootDir = $PSScriptRoot
if ($RootDir -eq "") { $RootDir = $pwd }

Import-Module ".\include\functions.psm1" -Force

# Get-Variables
. (Join-Path $RootDir variables.ps1)

Write-Host ""
Write-Log " Starting..."
Write-Host ""

# Setup temp output folder, and clear previous transcodes
Initialize-Folders

# Get Videos - run Scan job at $media_path or retrive videos from .\scan_results
$videos = Get-Videos

# run health check job 
Invoke-HealthCheck

# run color fix job
if ($mkv_color_fix -eq 1){Invoke-ColorFix}


# Get previously skipped files from skip.log
$skipped_files = Get-Skip
$skippederror_files = Get-SkipError
$skippedhevc_files = Get-SkipHEVC

#Show settings and any jobs running 
Show-State

# if single machine here - 
$skiptotal_files = $skipped_files + $skippederror_files + $skippedhevc_files

#Main Loop across videos 
$queue_timer = Get-Date
Foreach ($video in $videos) {

    # if duration has exceeded queue timer then re run the scan 
    $duration = $(Get-Date) - $queue_timer
    if ($duration.TotalMinutes -gt $restart_queue) {
        $videos = Get-Videos
        $skipped_files = Get-Skip
        $skippederror_files = Get-SkipError
        $skippedhevc_files = Get-SkipHEVC
        $skiptotal_files = $skipped_files + $skippederror_files + $skippedhevc_files
        $queue_timer = Get-Date
    }

    if ($($video.name) -notin $skiptotal_files) {

        $video_size = [math]::Round($video.length / 1GB, 2)
    
        if ($video_size -lt $min_video_size) { 
            Write-Log "HIT VIDEO SIZE LIMIT - waiting for running jobs to finish then quiting"
            while (get-job -State Running -ea silentlycontinue) {
                Start-Sleep 1
                Receive-Job *
            }   
            Write-Log "exiting"
            Read-Host -Prompt "Press any key to continue"
            exit
        }

        while ($true) {

            $done = 0

            for ($thread = 1; $thread -le $GPU_threads; $thread++) {
                # get thread state 
                $gpu_state = Get-JobStatus "GPU-$thread"

                # clear completed or stopped jobs 
                if ($gpu_state -eq "Completed" -OR $gpu_state -eq "Stopped") { 
                    Receive-Job -name "GPU-$thread" 
                    remove-job -name "GPU-$thread" -Force
                }   

                # has thread run too long? 
                $now = Get-Date
                Get-Job -name GPU-* | Where-Object { $_.State -eq 'Running' -and (($now - $_.PSBeginTime).TotalMinutes -gt $ffmpeg_timeout) } | Stop-Job

                # check for GPU driver issues 
                $ErrorCheckTime = Get-Date
                $ErrorCheckTime = $ErrorCheckTime.AddSeconds(-25)
                $ErrorCheck = $null
                $ErrorCheck = get-eventlog System -After $ErrorCheckTime | Where-Object { $_.EventID -eq 4101 }
                if ($null -ne $ErrorCheck) {      
                    Write-Host "  DETECTED DRIVER ISSUE." -NoNewline
                    Get-Job -name GPU-* | Stop-Job
                    Write-Host " All Jobs killed. Restarting after delay" -NoNewline
                    for ($delay = 0; $delay -lt 30 ; $delay++) {
                        Write-Host "." -NoNewline
                        Start-Sleep 1
                    }  
                    Write-Host "." 
                }

                # If thread not running then i can run it here 
                if ($gpu_state -ne "Running") {
                    if ($ffmpeg_hwdec -eq 1) { $hw = "DE" }
                    else { $hw = "E" }
                    Start-Job -Name "GPU-$thread" -FilePath .\include\job_transcode.ps1 -ArgumentList $RootDir, $video, "($thread$hw)" | Out-Null 
                    $done = 1 
                    break
                }       
                
                Receive-Job -name *
            }          
            if ($done -eq 1) { break }
        }
    }
}
Write-Log " Queue complete, waiting for running jobs to finish then quiting"
while (get-job -State Running -ea silentlycontinue) {
    Start-Sleep 1
    Receive-Job *
}   
Write-Log " exiting"
Start-Sleep 10
#Read-Host -Prompt "Press any key to continue"
exit