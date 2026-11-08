# Render one composition to an image sequence, then encode it with audio using a system ffmpeg
# (Remotion's bundled encoder crashed on this machine).
# Usage: .\render.ps1 ShortEN ww3-short-en     (needs ffmpeg on PATH; run `node make-audio.mjs public/track.wav` once)
param([string]$Comp, [string]$Name)
$seq = Join-Path $env:TEMP "ww3_seq_$Name"
if (Test-Path $seq) { Remove-Item $seq -Recurse -Force }
npx remotion render src/index.ts $Comp $seq --sequence --image-format=jpeg --jpeg-quality=94 | Select-Object -Last 1
$out = Join-Path (Split-Path $PSScriptRoot -Parent) "$Name.mp4"
ffmpeg -y -framerate 30 -i "$seq\element-%03d.jpeg" -i public\track.wav -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest -movflags +faststart $out 2>&1 | Select-Object -Last 1
Remove-Item $seq -Recurse -Force
Get-Item $out | Select-Object Name, Length
