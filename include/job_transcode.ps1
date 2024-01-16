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
$video_new_path = $video.Fullname

if ($ffmpeg_mp4 -eq 1) {
    $video_new_name = $video.Name
    $video_new_name = $video_new_name.Substring(0, $video_new_name.Length - 4)
    $video_new_name = "$video_new_name.mp4"
    $video_new_path = $video.Fullname
    $video_new_path = $video_new_path.Substring(0, $video_new_path.Length - 4)
    $video_new_path = "$video_new_path.mp4"
}

# Write-Host "Check if file is AV1 first..."
$video_codec = Get-VideoCodec $video_path
$audio_codec = Get-AudioCodec $video_path
$audio_channels = Get-AudioChannels $video_path

# check video width (1920 width is more consistant for 1080p videos)
$video_width = Get-VideoWidth $video_path

# check video duration 
$video_duration = Get-VideoDuration $video_path
# $video_duration_formated = Get-VideoDurationFormatted $video_duration 

$start_time = (GET-Date)

# Add to skip file so it is not processed again
# do at beginning so that stuff that times out does not get processed again. 
Write-Skip "$video_name"

# GPU Offload...
if ($video_codec -ne "av1") {
        
    $transcode_msg = "transcoding to AV1"

    # AMD TUNING - 
    if ($ffmpeg_video_codec -eq "av1_amf") { $ffmpeg_video_codec_tune = "-quality 30 -preset 5 -crf 22" }
    
    if ($ffmpeg_hwdec -eq 0) { $ffmpeg_dec_cmd = "" }
    elseif ($ffmpeg_hwdec -eq 1) { $ffmpeg_dec_cmd = "-hwaccel cuda -hwaccel_output_format cuda" }

    $ffmpeg_color_space_cmd = "-vf colorspace=all=bt709 -colorspace 1 -color_primaries 1 -color_trc 1"

    switch ($ffmpeg_aac) {
        0 { $ffmpeg_audio_cmd = "copy" }
        1 {
            $ffmpeg_audio_cmd = "aac -ac 2" 
            $transcode_msg = "$transcode_msg + AAC (2 channel)"
        }
        2 {
            $ffmpeg_audio_cmd = "libfdk_aac -ac 2"
            $transcode_msg = "$transcode_msg + libfdk AAC (2 channel)"
        }
    }
 
    if ($convert_1080p -eq 0) { $ffmpeg_scale_cmd = "" } 
    elseif ($convert_1080p -eq 1 -AND $video_width -gt 1920) { $ffmpeg_scale_cmd = "-vf scale=1920:-1" } 

    # if ($ffmpeg_mp4 -eq 1) { $transcode_msg = "$transcode_msg MP4" }

    $transcode_msg = "$transcode_msg..."
    Write-Log "$job - $video_name ($video_codec, $audio_codec($audio_channels channel), $video_width, $video_size`GB`) $transcode_msg"      
 
    # Main FFMPEG Params 
    #$ffmpeg_params = ".\ffmpeg.exe -hide_banner -err_detect ignore_err -ignore_unknown -v $ffmpeg_logging -y $ffmpeg_dec_cmd -i `"$video_path`" $ffmpeg_scale_cmd -map $ffmpeg_eng_cmd -map 0:v -c:v $ffmpeg_codec $ffmpeg_codec_tune -c:a $ffmpeg_aac_cmd -c:s copy -max_muxing_queue_size 9999 `"output\$video_new_name`" "
    #$ffmpeg_params = ".\ffmpeg.exe -hide_banner -err_detect ignore_err -ec guess_mvs+deblock+favor_inter -ignore_unknown -v $ffmpeg_logging -y $ffmpeg_dec_cmd -i `"$video_path`" $ffmpeg_scale_cmd $ffmpeg_color_space_cmd -c:v $ffmpeg_video_codec $ffmpeg_video_codec_tune -c:a $ffmpeg_audio_cmd -c:s copy -max_muxing_queue_size 9999 `"output\$video_new_name`" "
    $ffmpeg_params = ".\ffmpeg.exe -hide_banner -err_detect ignore_err -ec guess_mvs+deblock+favor_inter -ignore_unknown -v $ffmpeg_logging -y $ffmpeg_dec_cmd -i `"$video_path`" $ffmpeg_scale_cmd -c:v $ffmpeg_video_codec $ffmpeg_video_codec_tune -c:a $ffmpeg_audio_cmd -c:s copy -max_muxing_queue_size 9999 `"output\$video_new_name`" "

    # Write-Host $ffmpeg_params

    Invoke-Expression $ffmpeg_params -ErrorVariable err 
    if ($err) { 
        Write-Log "$job - $video_name $err"
        Write-SkipError "$video_name" 
        exit
    }

    $end_time = (GET-Date)
    # calc time taken 
    $time = $end_time - $start_time
    $time_hours = $time.hours
    $time_mins = $time.minutes
    $time_secs = $time.seconds 
    if ($time_secs -lt 10) { $time_secs = "0$time_secs" }
    $total_time_formatted = "$time_hours" + ":" + "$time_mins" + ":" + "$time_secs" 
    if ($time_hours -eq 0) { $total_time_formatted = "$time_mins" + ":" + "$time_secs" }

}

if (test-path -PathType leaf "output\$video_new_name") {        

    Start-Sleep 1

    # check size of new file 
    $video_new = Get-ChildItem output\$video_new_name | Select-Object Fullname, extension, length
    $video_new_size = [math]::Round($video_new.length / 1GB, 1)
    $diff = $video_size - $video_new_size
    $diff = [math]::Round($diff, 1)
    $diff_percent = [math]::Round((1 - ($video_new_size / $video_size)) * 100, 0)

    # check video length 
    $video_new_duration = $null 
    $video_new_duration = Get-VideoDuration output\$video_new_name

    # check new media audio and video codec
    $video_new_videocodec = $null
    $video_new_videocodec = Get-VideoCodec output\$video_new_name
    $video_new_audiocodec = $null
    $video_new_audiocodec = Get-AudioCodec output\$video_new_name
                 
    if ($video_width -gt 1920) { Write-Log "  New Transcoded Video Width: $video_width -> 1920" }
              
    # run checks, if ok then move... 
    if ($diff_percent -eq 100 -OR $video_new_size -eq 0) { 
        Write-Log "$job - $video_new_name ERROR, zero file size ($video_new_size`GB`), File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    }
    elseif ($diff_percent -lt $ffmpeg_min_diff ) {
        Write-Log "$job - $video_new_name ERROR, min difference too small ($diff_percent% < $ffmpeg_min_diff%) $video_size`GB -> $video_new_size`GB, File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    } 
    elseif ($diff_percent -gt $ffmpeg_max_diff ) {
        Write-Log "$job - $video_new_name ERROR, max too high ($diff_percent% > $ffmpeg_max_diff%) $video_size`GB -> $video_new_size`GB, File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    }        
    elseif ($video_new_duration -lt ($video_duration - 5) -OR $video_new_duration -gt ($video_duration + 5)) { 
        Write-Log "$job - $video_new_name ERROR, incorrect duration on new video ($video_duration -> $video_new_duration), File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    }
    elseif ($null -eq $video_new_videocodec) { 
        Write-Log "$job - $video_new_name ERROR, no video stream detected, File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    }
    elseif ($null -eq $video_new_audiocodec) { 
        Write-Log "$job - $video_new_name ERROR, no audio stream detected, File NOT moved" 
        Remove-Item "output\$video_new_name"
        Write-SkipError "$video_name"
    }
    elseif ($move_file -eq 0) { 
        Write-Log "$job - $video_new_name Transcode time: $total_time_formatted, Saved: $diff`GB` ($video_size -> $video_new_size) or $diff_percent%"
        Write-Log "$job - $video_new_name move file disabled, File NOT moved" }
    # File passes all checks, move....
    else { 
        Write-Log "$job - $video_new_name Transcode time: $total_time_formatted, Saved: $diff`GB` ($video_size -> $video_new_size) or $diff_percent%"
        Write-Host "  $video_new_name (duration $video_duration -> $video_new_duration, video codec $video_codec -> $video_new_videocodec, audio codec $audio_codec -> $video_new_audiocodec)"
        Start-delay
        try {
            $extension = Get-ChildItem output\$video_new_name | Select-Object Extension 
            if ($extension.Extension -eq ".mkv") { 
                .\mkvpropedit.exe `"output\$video_new_name`" --edit track:v1 -d color-matrix-coefficients -d chroma-siting-horizontal -d chroma-siting-vertical -d color-transfer-characteristics -d color-range -d color-primaries --quiet | Out-Null
            }                  
            Move-item -Path "output\$video_new_name" -destination "$video_new_path" -Force 
            if ($ffmpeg_mp4 -eq 1) { Remove-Item "$video_path" }
            Write-SkipAV1 $video_new_name
        }
        catch {
            Write-Log "Error moving $video_new_name back to source location - Check permissions"   
            Write-Log $_.exception.message 
            exit
        }
    }   
}

Else {   

    if ($video_codec -eq "av1") {
        Write-Log  "$job - $video_name ($video_codec, $video_width, $video_size GB) Already AV1, Skipping"
        Write-SkipAV1 $video_name
        exit
    }
    
    else { 
        Write-Log "$job - $video_name ($video_codec, $video_width, $video_size GB) ERROR or FAILED"
        Write-SkipError $video_name
        exit
    }                                
} 
