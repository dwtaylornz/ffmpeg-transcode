Set-Location $args[0]

$RootDir = $PSScriptRoot
if ($RootDir -eq ""){ $RootDir = $pwd }

# grab variables from var file 
. (Join-Path $RootDir variables.ps1)

# Get all video files and sizes (sorting largest to smallest)
$videoExtensions = "*.mkv", "*.avi", "*.ts", "*.mov", "*.y4m", "*.m2ts", "*.mp4", "*.wmv"
$allVideos = @()

foreach ($path in $media_path) {
    $videos = Get-ChildItem -r $path -Include $videoExtensions | 
              Select-Object Fullname, Name, Length
    $allVideos += $videos
}

$allVideos = $allVideos | Sort-Object -Descending -Property Length

$allVideos | Export-Csv "$log_path\scan_results.csv" -Encoding utf8