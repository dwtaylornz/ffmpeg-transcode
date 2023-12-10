Set-Location $args[0]
$videos = $args[1]

Import-Module ".\include\functions.psm1" -Force

$unhealthyVideos = @()

foreach ($video in $videos) {
    $video_path = $video.Fullname
    $video_duration = Get-VideoDuration $video_path
    $media_audiocodec = Get-AudioCodec $video_path
    $media_videocodec = Get-VideoCodec $video_path

    $isBroken = $false
    $brokenReason = ""

    if ($video_duration -lt 1) {
        $isBroken = $true
        $brokenReason += "Video length = $video_duration. "
    }
    if ($null -eq $media_audiocodec) {
        $isBroken = $true
        $brokenReason += "It has no audio stream. "
    }
    if ($null -eq $media_videocodec) {
        $isBroken = $true
        $brokenReason += "It has no video stream. "
    }

    if ($isBroken) {
        Write-Output "I think $video_path is broken, $brokenReason"
        $unhealthyVideos += $video
    }
}

$unhealthyVideos | Export-Csv unhealthy.csv -append