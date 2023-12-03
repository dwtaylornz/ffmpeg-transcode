Set-Location $args[0]
$videos = $args[1]

Import-Module ".\include\functions.psm1" -Force

$RootDir = $PSScriptRoot
if ($RootDir -eq "") { $RootDir = $pwd }

# Get-Variables
. (Join-Path $RootDir variables.ps1)

$colorfixed_files = Get-ColorFixed

Foreach ($video in $videos) {

    if ($($video.name) -notin $colorfixed_files) {

        $video_new_path = $video.FullName
        $extension = Get-ChildItem $video.FullName | Select-Object Extension 

        if ($extension.Extension -eq ".mkv") { 
            .\mkvpropedit.exe `"$video_new_path`" --edit track:v1 -d color-matrix-coefficients -d chroma-siting-horizontal -d chroma-siting-vertical -d color-transfer-characteristics -d color-range -d color-primaries --quiet | Out-Null
            $video_name = $video.name
            Write-ColorFixed "$video_name"
        }

    }

}

Write-Log " - ColorFix complete on all files. Color headers removed!"