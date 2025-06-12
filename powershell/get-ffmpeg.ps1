$url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z"
$outputFolder = "download"

./ffmpeg -version | Select-Object -First 1  

# Download the archive (silently)
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $url -OutFile "ffmpeg-git-full.7z" > $null

# Extract the archive using 7-Zip (quieter)
& "C:\Program Files\7-Zip\7z.exe" x ffmpeg-git-full.7z -o"$outputFolder" -aoa -bso0 -bsp0

# Move the contents of /bin to the current directory (suppress output)
Move-Item -Path "$outputFolder\ffmpeg*\bin\*" -Destination . -Force > $null

# Clean up: remove the downloaded archive (suppress output)
Remove-Item "ffmpeg-git-full.7z" -Force > $null
Remove-Item -Path $outputFolder -Recurse -Force > $null

./ffmpeg -version | Select-Object -First 1