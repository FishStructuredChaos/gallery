param([switch]$DryRun)

$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$startTime = Get-Date
$thumbRoot = Join-Path $scriptDir '_thumbs'
$cachePath = Join-Path $scriptDir '_compressed-images.json'

$magickCmd = $null
foreach ($cmd in @('magick', 'magick.exe', 'convert')) {
    $path = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($path) { $magickCmd = $cmd; break }
}
if (-not $magickCmd) {
    $commonPaths = @(
        "$env:ProgramFiles\ImageMagick*\magick.exe",
        "${env:ProgramFiles(x86)}\ImageMagick*\magick.exe",
        "$env:LOCALAPPDATA\ImageMagick*\magick.exe"
    )
    foreach ($pattern in $commonPaths) {
        $exe = Resolve-Path $pattern -ErrorAction SilentlyContinue
        if ($exe) { $magickCmd = $exe.Path; break }
    }
}

$hasMagick = $null -ne $magickCmd
$hasDotNet = $false
try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $null = [System.Drawing.Image]; $hasDotNet = $true } catch {}

if (-not $hasMagick -and -not $hasDotNet) {
    Write-Host "  ERROR: No image tool found. Install ImageMagick from imagemagick.org" -ForegroundColor Red
    Start-Sleep -Seconds 8; exit 1
}

$toolLabel = if ($hasMagick) { "ImageMagick ($magickCmd)" } else { ".NET (slower, no GIF support)" }
$toolColor = if ($hasMagick) { 'Cyan' } else { 'Yellow' }

Write-Host "+---------------------------------------------------------------+" -ForegroundColor DarkGreen
Write-Host "|                         COMPRESS IMAGES                         |" -ForegroundColor Green
Write-Host "+---------------------------------------------------------------+" -ForegroundColor DarkGreen
Write-Host "  Tool:   " -NoNewline; Write-Host "$toolLabel" -ForegroundColor $toolColor
if ($DryRun) { Write-Host "  Mode:   " -NoNewline; Write-Host "DRY RUN (no changes)" -ForegroundColor Yellow; Write-Host "" }
else { Write-Host "" }

# --- DELETE_* cleanup (also removes matching thumbnails) ---
$deleted = Get-ChildItem -LiteralPath $scriptDir -Filter 'DELETE_*' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[/\\]\.git[/\\]' }
if ($deleted.Count -gt 0) {
    foreach ($f in $deleted) {
        $rel = $f.FullName.Substring($scriptDir.Length + 1)
        $relNoPrefix = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($rel), ([System.IO.Path]::GetFileName($rel) -replace '^DELETE_', ''))
        $thumbPath = Join-Path $thumbRoot ([System.IO.Path]::ChangeExtension($relNoPrefix, '.webp'))
        if (Test-Path -LiteralPath $thumbPath) { Remove-Item -LiteralPath $thumbPath -Force }
        Remove-Item -LiteralPath $f.FullName -Force
    }
    Write-Host "  Deleted $($deleted.Count) DELETE_* file(s)" -ForegroundColor DarkGray
}

$files = Get-ChildItem -LiteralPath $scriptDir -File -Recurse | Where-Object {
    $_.Extension -match '\.(jpg|jpeg|png|gif)$' -and
    $_.FullName -notmatch '[/\\]\.git[/\\]'
} | Sort-Object Length -Descending

$total = $files.Count
if ($total -eq 0) {
    Write-Host "  No images found. Nothing to do." -ForegroundColor Gray
    Write-Host ""; exit 0
}

Write-Host "  Found " -NoNewline; Write-Host "$total images" -NoNewline; Write-Host " to process..."

$gifCount = ($files | Where-Object { $_.Extension -eq '.gif' }).Count
if ($gifCount -gt 0 -and -not $hasMagick) {
    Write-Host "  !! $gifCount GIF(s) found - ImageMagick not detected, GIFs will be SKIPPED" -ForegroundColor Yellow
    Write-Host "    Install from: https://imagemagick.org" -ForegroundColor DarkGray
}
Write-Host ""

$processed = 0; $skipped = 0; $failed = 0; $bytesSaved = 0; $renamedJpeg = 0; $cached = 0

$cache = @{}
if (Test-Path $cachePath) {
    try {
        $raw = Get-Content $cachePath -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { if ($prop.Name -match '^[a-f0-9]{32}$') { $cache[$prop.Name] = $true } }
        Write-Host "  Loaded cache with $($cache.Count) entries" -ForegroundColor DarkGray
    } catch {}
}

if ($hasMagick) {
    $groups = $files | Group-Object { $_.Extension.ToLower() }
    Write-Host "  Using batch mogrify (fastest)" -ForegroundColor Gray

    foreach ($group in $groups) {
        $ext = $group.Name
        $fileList = @(); $fileHashes = @{}; $cachedInGroup = 0

        foreach ($f in $group.Group) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash
            if ($cache.ContainsKey($hash)) { $cachedInGroup++; continue }
            $fileList += $f; $fileHashes[$f.FullName] = $hash
        }

        $count = $fileList.Count; $cached += $cachedInGroup

        $label = "  [$ext] $count to process"
        if ($cachedInGroup -gt 0) { $label += " ($cachedInGroup already compressed, skipped)" }
        Write-Host $label

        $mogrifyArgs = @()
        switch ($ext) {
            '.jpg'  { $mogrifyArgs = @('-sampling-factor', '4:2:0', '-strip', '-quality', '85', '-interlace', 'JPEG') }
            '.jpeg' { $mogrifyArgs = @('-sampling-factor', '4:2:0', '-strip', '-quality', '85', '-interlace', 'JPEG', '-format', 'jpg') }
            '.png'  { $mogrifyArgs = @('-strip', '-define', 'png:compression-level=9', '-define', 'png:compression-filter=5', '-define', 'png:compression-strategy=1') }
            '.gif'  { $mogrifyArgs = @('-strip', '-layers', 'Optimize') }
        }

        if ($count -eq 0 -or $DryRun) {
            if ($DryRun) { $skipped += $count }
            continue
        }

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $batchSize = 200
        for ($s = 0; $s -lt $count; $s += $batchSize) {
            $e = [math]::Min($s + $batchSize - 1, $count - 1)
            & $magickCmd mogrify -path $tempDir @mogrifyArgs $($fileList[$s..$e].FullName) 2>$null
        }

        $groupProcessed = 0; $groupSkipped = 0; $groupSaved = 0; $groupRenamed = 0
        for ($idx = 0; $idx -lt $count; $idx++) {
            $f = $fileList[$idx]
            $outputName = if ($ext -eq '.jpeg') { [System.IO.Path]::ChangeExtension($f.Name, '.jpg') } else { $f.Name }
            $tempFile = Join-Path $tempDir $outputName

            if (-not (Test-Path $tempFile)) { $groupSkipped++; continue }

            $origSize = $f.Length; $newSize = (Get-Item $tempFile).Length
            Write-Host "`r    [$($idx+1)/$count] $($f.Name)$(' ' * 80)" -NoNewline

            if ($ext -eq '.jpeg') {
                $newPath = Join-Path $f.DirectoryName ([System.IO.Path]::ChangeExtension($f.Name, '.jpg'))
                if (Test-Path -LiteralPath $newPath) {
                    Remove-Item -LiteralPath $f.FullName -Force
                    $groupRenamed++
                } else {
                    Copy-Item -LiteralPath $tempFile -Destination $f.DirectoryName -Force
                    Remove-Item -LiteralPath $f.FullName -Force
                    $groupSaved += [math]::Max(0, $origSize - $newSize); $groupProcessed++; $groupRenamed++
                    if (Test-Path -LiteralPath $newPath) { $cache[(Get-FileHash -LiteralPath $newPath -Algorithm MD5).Hash] = $true }
                }
            } elseif ($newSize -lt $origSize -and $newSize -gt 0) {
                Copy-Item $tempFile $f.FullName -Force
                $groupSaved += $origSize - $newSize; $groupProcessed++
                $cache[(Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash] = $true
            } else {
                $groupSkipped++
                $cache[$fileHashes[$f.FullName]] = $true
            }
        }

        $processed += $groupProcessed; $skipped += $groupSkipped; $bytesSaved += $groupSaved
        $renamedJpeg += $groupRenamed

        Write-Host ""
        if ($groupSaved -gt 0) {
            $savedKb = [math]::Round($groupSaved/1KB, 1)
            Write-Host "    $groupProcessed compressed, -$savedKb KB" -ForegroundColor Green
        } else {
            Write-Host "    $groupProcessed compressed" -ForegroundColor Gray
        }

        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        try { $cache | ConvertTo-Json | Set-Content $cachePath -Encoding UTF8 } catch {}
    }
}

if (-not $hasMagick -and $hasDotNet) {
    for ($i = 0; $i -lt $total; $i++) {
        $f = $files[$i]; $ext = $f.Extension.ToLower()
        if ($ext -eq '.gif') { continue }
        $origSize = $f.Length
        $rel = $f.FullName.Substring($scriptDir.Length + 1)

        Write-Host "  [$($i+1)/$total] $rel " -NoNewline
        if ($DryRun) { Write-Host ""; continue }

        $tempFile = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName() + $ext
        try {
            $img = [System.Drawing.Image]::FromFile($f.FullName)
            if ($img.Width -gt 8000 -or $img.Height -gt 8000) {
                Write-Host "(too large for .NET)" -ForegroundColor DarkGray
                $img.Dispose(); $skipped++; continue
            }
            if ($ext -eq '.jpg' -or $ext -eq '.jpeg') {
                $enc = [System.Drawing.Imaging.Encoder]::Quality
                $prm = New-Object System.Drawing.Imaging.EncoderParameters(1)
                $prm.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter($enc, [long]85)
                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
                $img.Save($tempFile, $codec, $prm)
            } else {
                $img.Save($tempFile, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            $img.Dispose()

            if (Test-Path $tempFile) {
                $newSize = (Get-Item $tempFile).Length
                if ($newSize -lt $origSize -and $newSize -gt 0) {
                    $saved = $origSize - $newSize
                    $pct = [math]::Round(($saved / $origSize) * 100, 1)
                    $origKb = [math]::Round($origSize/1KB, 1); $newKb = [math]::Round($newSize/1KB, 1)
                    Copy-Item $tempFile $f.FullName -Force
                    $bytesSaved += $saved; $processed++

                    if ($ext -eq '.jpeg') {
                        $jpgPath = [System.IO.Path]::ChangeExtension($f.FullName, '.jpg')
                        if (Test-Path $jpgPath) { Remove-Item $jpgPath -Force }
                        Rename-Item $f.FullName -NewName ([System.IO.Path]::GetFileName($jpgPath)) -Force
                        $renamedJpeg++
                        Write-Host "($origKb KB -> $newKb KB, -$pct%) .jpeg -> .jpg" -ForegroundColor Magenta
                    } else {
                        if ($pct -ge 40) { $c = 'Green' } elseif ($pct -ge 20) { $c = 'Cyan' } else { $c = 'Gray' }
                        Write-Host "($origKb KB -> $newKb KB, -$pct%)" -ForegroundColor $c
                    }
                } else {
                    $origKb = [math]::Round($origSize/1KB, 1); Write-Host "($origKb KB) no savings" -ForegroundColor DarkGray
                    $skipped++
                }
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'Out of memory') { Write-Host "(too large for .NET)" -ForegroundColor DarkGray }
            else { Write-Host "FAILED" -ForegroundColor Red }
            $failed++
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$savedMb = [math]::Round($bytesSaved/1MB, 2)

Write-Host ""
Write-Host "+---------------------------------------------------------------+" -ForegroundColor DarkGreen
Write-Host "|                          SUMMARY                               |" -ForegroundColor Green
Write-Host "+---------------------------------------------------------------+" -ForegroundColor DarkGreen
Write-Host "  Time:      $elapsed seconds"
Write-Host "  Compressed: " -NoNewline; Write-Host "$processed" -ForegroundColor Green
if ($renamedJpeg -gt 0) { Write-Host "  Renamed:   " -NoNewline; Write-Host "$renamedJpeg .jpeg -> .jpg" -ForegroundColor Magenta }
Write-Host "  Skipped:   " -NoNewline; Write-Host "$skipped" -ForegroundColor Gray
if ($failed -gt 0) { Write-Host "  Failed:    " -NoNewline; Write-Host "$failed" -ForegroundColor Red }
if ($cached -gt 0) { Write-Host "  Cached:    " -NoNewline; Write-Host "$cached already compressed" -ForegroundColor DarkGray }
if ($bytesSaved -gt 0) {
    $origTotal = ($files | Measure-Object -Property Length -Sum).Sum
    Write-Host "  Saved:     " -NoNewline; Write-Host "$savedMb MB ($([math]::Round(($bytesSaved / $origTotal) * 100, 1))%)" -ForegroundColor Cyan
}
Write-Host ""

try { $cache | ConvertTo-Json | Set-Content $cachePath -Encoding UTF8 } catch {}

if ($hasMagick -and -not $DryRun) {
    Write-Host "  Generating thumbnails..." -ForegroundColor Gray
    $galleryDirs = Get-ChildItem -LiteralPath $scriptDir -Directory | Where-Object {
        $_.Name -notmatch '^[._]' -and $_.Name -ne 'node_modules' -and
        (Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $_.Extension -match '\.(jpg|jpeg|png|gif)$' }).Count -gt 0
    }
    $thumbCount = 0; $thumbSkipped = 0
    foreach ($dir in $galleryDirs) {
        $thumbDir = Join-Path $thumbRoot $dir.Name
        New-Item -ItemType Directory -Path $thumbDir -Force | Out-Null

        $nonGifs = Get-ChildItem -LiteralPath $dir.FullName -File | Where-Object {
            $_.Extension -match '\.(jpg|jpeg|png)$' -and $_.Length -gt 102400
        }
        $missing = @()
        foreach ($f in $nonGifs) {
            $thumbPath = Join-Path $thumbDir ($f.BaseName + '.webp')
            if (Test-Path $thumbPath) {
                $thumbItem = Get-Item -LiteralPath $thumbPath
                if ($thumbItem.LastWriteTimeUtc -ge $f.LastWriteTimeUtc) { $thumbSkipped++ }
                else {
                    Remove-Item -LiteralPath $thumbPath -Force
                    $missing += $f
                }
            } else { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            $batchSize = 200
            for ($s = 0; $s -lt $missing.Count; $s += $batchSize) {
                $e = [math]::Min($s + $batchSize - 1, $missing.Count - 1)
                & $magickCmd mogrify -path $thumbDir -resize 400x400 -quality 80 -strip -format webp $($missing[$s..$e].FullName) 2>$null
            }
            $thumbCount += $missing.Count
        }

        $gifs = Get-ChildItem -LiteralPath $dir.FullName -File | Where-Object {
            $_.Extension -eq '.gif' -and $_.Length -gt 102400
        }
        foreach ($g in $gifs) {
            $out = Join-Path $thumbDir ([System.IO.Path]::GetFileNameWithoutExtension($g.Name) + '.webp')
            if (Test-Path $out) {
                $outItem = Get-Item -LiteralPath $out
                if ($outItem.LastWriteTimeUtc -ge $g.LastWriteTimeUtc) { $thumbSkipped++; continue }
                Remove-Item -LiteralPath $out -Force
            }
            & $magickCmd convert "$($g.FullName)[0]" -resize 400x400 -quality 80 -strip $out 2>$null
            $thumbCount++
        }
    }
    Write-Host "    $thumbCount thumbnails generated" -NoNewline; if ($thumbSkipped -gt 0) { Write-Host ", $thumbSkipped already exist (skipped)" -ForegroundColor DarkGray } else { Write-Host "" -ForegroundColor Green }

    # --- Orphan cleanup: thumbs whose original no longer exists ---
    $orphans = 0
    $thumbFiles = Get-ChildItem -LiteralPath $thumbRoot -File -Filter '*.webp' -Recurse -ErrorAction SilentlyContinue
    foreach ($t in $thumbFiles) {
        $rel = $t.FullName.Substring($thumbRoot.Length + 1)
        $srcDir = Split-Path (Join-Path $scriptDir $rel) -Parent
        $base = [System.IO.Path]::GetFileNameWithoutExtension($t.Name)
        $exists = $false
        foreach ($ext in @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg')) {
            if (Test-Path -LiteralPath (Join-Path $srcDir ($base + $ext))) { $exists = $true; break }
        }
        if (-not $exists) { Remove-Item -LiteralPath $t.FullName -Force; $orphans++ }
    }
    if ($orphans -gt 0) { Write-Host "    Removed $orphans orphaned thumbnail(s)" -ForegroundColor DarkGray }

    # --- Remove empty thumbnail folders ---
    $emptyDirs = Get-ChildItem -LiteralPath $thumbRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
        -not (Get-ChildItem -LiteralPath $_.FullName -File -Force -ErrorAction SilentlyContinue)
    }
    foreach ($d in ($emptyDirs | Sort-Object { $_.FullName.Length } -Descending)) {
        Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '  Manifest will update automatically.' -ForegroundColor Gray
Write-Host ""
