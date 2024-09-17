$url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z"
$outputFolder = "download"

./ffmpeg -version | Select-Object -First 1  

# Download the archive
Invoke-WebRequest -Uri $url -OutFile "ffmpeg-git-full.7z"

# Extract the archive using 7-Zip
& "C:\Program Files\7-Zip\7z.exe" x ffmpeg-git-full.7z -o"$outputFolder" -aoa

# Move the contents of /bin to the current directory
Move-Item -Path "$outputFolder\ffmpeg*\bin\*" -Destination . -Force

# Clean up: remove the downloaded archive
Remove-Item "ffmpeg-git-full.7z"
Remove-Item -Path $outputFolder -Recurse -Force

./ffmpeg -version | Select-Object -First 1  
