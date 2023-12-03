Set-Location $args[0]
$videos = $args[1]

Import-Module ".\include\functions.psm1" -Force

Foreach ($video in $videos) {
    $video_duration = 0
    $video_path = $video.Fullname
    # Write-Output $video_name
    $video_duration = Get-VideoDuration $video_path
    $media_audiocodec = Get-AudioCodec $video_path
    $media_videocodec = Get-VideoCodec $video_path
    if ($video_duration -lt 1) {
        write-output "I think $video_path is broken, video length = $video_duration"
        write-output $video | Export-Csv unhealthy.csv -append
    }
    if ($null -eq $media_audiocodec) {
        write-output "I think $video_path is broken, it has no audio stream"
        write-output $video | Export-Csv unhealthy.csv -append
    }
    if ($null -eq $media_videocodec) {
        write-output "I think $video_path is broken, it has no video stream"
        write-output $video | Export-Csv unhealthy.csv -append
    }
}