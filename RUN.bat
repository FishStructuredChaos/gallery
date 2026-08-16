@echo off
setlocal enabledelayedexpansion

color 0A

echo.
echo ========================================
echo          COMPRESS IMAGES
echo   Compresses JPG, PNG, GIF files
echo   Converts .jpeg to .jpg
echo ========================================
echo.
echo Requirements: ImageMagick (recommended) or .NET runtime
echo.
echo This will:
echo  - Compress all JPEG, PNG, GIF images in subfolders
echo  - Convert .jpeg files to .jpg
echo  - Strip metadata while keeping good quality
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\compress-images.ps1"

echo.
echo ========================================
echo        UPDATE GALLERY MANIFEST
echo   Scans folders and generates image listings
echo ========================================
echo.

REM Try Node.js first for speed
node --version >nul 2>&1
if %errorlevel% equ 0 (
    node "%~dp0scripts\generate-manifest.js"
    goto done
)

REM Fall back to PowerShell
powershell -Command "exit" >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\generate-manifest.ps1"
    goto done
)

echo ERROR: Neither Node.js nor PowerShell found!
echo.
pause
exit /b 1

:done
echo.
echo ========================================
echo       ALL DONE!
echo   Open index.html to view the gallery
echo ========================================
echo.
pause
