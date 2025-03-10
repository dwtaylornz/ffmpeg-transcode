Set-Location $args[0]
$video = $args[1]
$job = $args[2]

Import-Module ".\include\functions.psm1" -Force

$RootDir = $PSScriptRoot
if ($RootDir -eq "") { $RootDir = $pwd }

# Get-Variables
. (Join-Path $RootDir variables.ps1)

# write-host "start-transcode" 
$video_name = $video.name
$video_path = $video.Fullname
$video_size = [math]::Round($video.length / 1GB, 1)
$video_new_name = $video.Name

# Write-Host "Check video codec first..."
$video_codec = Get-VideoCodec "$video_path"
$video_age = Get-VideoAge "$video_path"

# GPU Offload...
if ($video_codec -notin $video_codec_skip_list -AND $video_age -ge $min_video_age) {

    # check audio codec and channels, video width and duration

    $audio_codec = Get-AudioCodec "$video_path"
    $audio_channels = Get-AudioChannels "$video_path"
    $video_width = Get-VideoWidth "$video_path"
    $video_duration = Get-VideoDuration "$video_path"

    $start_time = (GET-Date)

    Write-Skip "$video_name"

    $transcode_msg = "transcoding using ($ffmpeg_parameters)..."
    Write-Log "$job - $video_name ($video_codec, $audio_codec($audio_channels channel), $video_width, $video_size`GB`, $video_age days old) $transcode_msg"    
    $output_path = "output\$video_new_name"
 
    # Main FFMPEG Params 
    $ffmpeg_params = ".\ffmpeg.exe -y -hide_banner -err_detect ignore_err -ignore_unknown -v $ffmpeg_logging -i `"$video_path`" $ffmpeg_parameters -max_muxing_queue_size 9999 `"$output_path`""

    Invoke-Expression $ffmpeg_params -ErrorVariable err 
    if ($err) { 
        Write-Log "$job - $video_name $err"
        Write-SkipError "$video_name" 
        exit
    }

    $end_time = (Get-Date)
    # Calculate time taken
    $time = $end_time - $start_time
    $time_hours = $time.Hours
    $time_mins = $time.Minutes.ToString("D2")
    $time_secs = $time.Seconds.ToString("D2")
    $total_time_formatted = if ($time_hours -eq 0) {
        "${time_mins}:${time_secs}"
    } else {
        "${time_hours}:${time_mins}:${time_secs}"
    }

}
elseif ($video_codec -in $video_codec_skip_list) {
    Write-Log  "$job - $video_name ($video_codec, $video_size GB, $video_age days old) in video codec skip list, skipping"
    Write-Skip $video_name
    exit
}
else {
    Write-Log  "$job - $video_name ($video_codec, $video_size GB, $video_age days old) is too new to transcode, skipping"
    exit
}

Start-Sleep 5

try {        
    
    # Write-Host "Checking path: $output_path"
    # check size of new file 
    $video_new = Get-ChildItem ""$output_path"" -ErrorAction Stop | Select-Object Fullname, extension, length
    $video_new_size = [math]::Round($video_new.length / 1GB, 1)
    $diff = [math]::Round(($video_size - $video_new_size), 1)
    $diff_percent = [math]::Round((1 - ($video_new_size / $video_size)) * 100, 0)

    # calculate how many minutes per gb of orignal size 
    $gb_per_minute = [math]::Round(($video_size / ($time.TotalSeconds / 60)), 2)
    
    #debug
    # Write-Host "video_new: $video_new"
    # Write-Host "video_new.length: $video_new.length"
    # Write-Host "video_new_size: $video_new_size"

    # check 
    $video_new_duration = Get-VideoDuration "output\$video_new_name"
    $video_new_videocodec = Get-VideoCodec "output\$video_new_name"
    $video_new_audiocodec = Get-AudioCodec "output\$video_new_name"
                            
    # run checks, if ok then move... 
    if ($video_new_size -eq 0) { 
        Write-Log "$job - $video_new_name ERROR, zero file size ($video_new_size`GB`), File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    }
    elseif ($video_new_duration -lt ($video_duration - 10) -OR $video_new_duration -gt ($video_duration + 10)) { 
        Write-Log "$job - $video_new_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    }
    elseif ($null -eq $video_new_videocodec) { 
        Write-Log "$job - $video_new_name ERROR, no video stream detected, File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    }
    elseif ($null -eq $video_new_audiocodec) { 
        Write-Log "$job - $video_new_name ERROR, no audio stream detected, File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    }
    elseif ($diff_percent -lt $ffmpeg_min_diff ) {
        Write-Log "$job - $video_new_name ERROR, min difference too small ($diff_percent% < $ffmpeg_min_diff%) $video_size`GB -> $video_new_size`GB, File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    } 
    elseif ($diff_percent -gt $ffmpeg_max_diff ) {
        Write-Log "$job - $video_new_name ERROR, max too high ($diff_percent% > $ffmpeg_max_diff%) $video_size`GB -> $video_new_size`GB, File NOT moved" 
        Get-VideoDebugInfo
        Write-SkipError $video_name 
    }        
   
    elseif ($move_file -eq 0) { 
        Write-Log "$job - $video_new_name Transcode time: $total_time_formatted, Saved: $diff`GB` ($video_size -> $video_new_size) or $diff_percent%"
        Write-Log "$job - $video_new_name move file disabled, File NOT moved" 
    }
    # File passes all checks, move....
    else { 
        Write-Log "$job - $video_new_name Transcode time: $total_time_formatted ($gb_per_minute GB/m), Saved: $diff`GB` ($video_size -> $video_new_size) or $diff_percent%"
        Write-Host "  $video_new_name (video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec)"
        try {
            Start-delay
            # Write-Log "  Moving file to source location ($output_path -> $video_path)"
            Move-Item -LiteralPath "$output_path" -Destination "$video_path" -Force 
            Write-Skip $video_new_name
            Start-Sleep 2
            if (Test-Path -LiteralPath "$output_path") { 
                Remove-Item -LiteralPath "$output_path" -Force
            }
        }
        catch {
            Write-Log "Error moving $video_new_name back to source location - Check permissions"   
            Write-Log $_.exception.message 
            exit
        }
    }   
}
catch { 
    Write-Log "$job - $video_name ($video_codec, $video_width, $video_duration, $video_size GB) ERROR or FAILED - output not found"
    write-Log "$job - $video_name ERROR cannot find output\$video_new_name"
    Write-SkipError $video_name 
    exit
}                                