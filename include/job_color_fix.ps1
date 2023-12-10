Set-Location $args[0]
$videos = $args[1]

Import-Module ".\include\functions.psm1" -Force

$RootDir = if ($PSScriptRoot -eq "") { $pwd } else { $PSScriptRoot }

. (Join-Path $RootDir variables.ps1)

$colorfixed_files = Get-ColorFixed

$videos | Where-Object { $_.name -notin $colorfixed_files -and $_.Extension -eq ".mkv" } | ForEach-Object {
    .\mkvpropedit.exe "`"$($_.FullName)`"" --edit track:v1 -d color-matrix-coefficients -d chroma-siting-horizontal -d chroma-siting-vertical -d color-transfer-characteristics -d color-range -d color-primaries --quiet | Out-Null
    Write-ColorFixed "$($_.name)"
}

Write-Log " - ColorFix complete on all files. Color headers removed!"