Set-Location $args[0]

$RootDir = $PSScriptRoot
if ($RootDir -eq ""){ $RootDir = $pwd }

# grab variables from var file 
. (Join-Path $RootDir variables.ps1)

#Write-Host -NoNewline "Checking all video files and sizes (sorting largest to smallest)..." 
# HEVC not supported in some .MP4 containers
# $videos = Get-ChildItem -r $media_path -Include *.mkv, *.avi, *.mp4, *.ts, *.mov, *.y4m, *.m2ts | Sort-Object -descending -Property length | Select-Object Fullname, name, length
$videos = Get-ChildItem -r $media_path -Include *.mkv, *.avi, *.ts, *.mov, *.y4m, *.m2ts, *.mp4 | Sort-Object -descending -Property length | Select-Object Fullname, name, length
$videos | Export-Csv $log_path\scan_results.csv -Encoding utf8