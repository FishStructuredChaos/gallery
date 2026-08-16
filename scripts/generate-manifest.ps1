$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

$folders = Get-ChildItem -Path $scriptDir -Directory | Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'node_modules' }
$result = @{ folders = @(); thumbsDir = '_thumbs' }
$totalImages = 0

foreach ($folder in $folders) {
    $extPriority = @{ '.png' = 0; '.svg' = 1; '.jpg' = 2; '.jpeg' = 3; '.gif' = 4; '.webp' = 5; '.bmp' = 6 }
    $files = Get-ChildItem -Path $folder.FullName -File | Where-Object {
        $_.Name -notlike 'DELETE_*' -and $extPriority.ContainsKey($_.Extension.ToLower())
    }
    if ($files.Count -eq 0) { continue }
    $sorted = $files | Sort-Object @{ Expression = { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } }, @{ Expression = { $extPriority[[System.IO.Path]::GetExtension($_.Name).ToLower()] } }
    $fileList = $sorted | ForEach-Object { $_.Name }
    $sizes = $sorted | ForEach-Object { $_.Length }
    $result.folders += @{
        name = $folder.Name
        path = $folder.Name
        files = $fileList
        sizes = $sizes
        count = $fileList.Count
    }
    Write-Host "  $($folder.Name): $($fileList.Count) images"
    $totalImages += $fileList.Count
}

$json = $result | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText("$scriptDir\manifest.json", $json)
[System.IO.File]::WriteAllText("$scriptDir\manifest.js", "window.MANIFEST = $json;")

Write-Host ""
Write-Host "manifest.json + manifest.js regenerated!"
Write-Host "Total folders: $($result.folders.Count)"
Write-Host "Total images:  $totalImages"
Start-Sleep -Seconds 3
