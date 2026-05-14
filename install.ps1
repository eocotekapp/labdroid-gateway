$ErrorActionPreference = "SilentlyContinue"

$InstallDir = "$HOME\.labdroid"
$RawBase = "https://raw.githubusercontent.com/USERNAME/labdroid-gateway/main"

Write-Host ""
Write-Host "======================================="
Write-Host "        LabDroid Gateway Installer"
Write-Host "             Windows Edition"
Write-Host "======================================="
Write-Host ""

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

function Has-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Add-UserPath($path) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current -notlike "*$path*") {
        [Environment]::SetEnvironmentVariable("Path", "$current;$path", "User")
        $env:Path = "$env:Path;$path"
    }
}

function Install-ADB {
    if (Has-Command "adb") {
        Write-Host "[OK] adb đã có, bỏ qua."
        return
    }

    Write-Host "[LabDroid] Chưa có adb. Đang tải Android platform-tools..."

    $ZipPath = "$InstallDir\platform-tools.zip"
    $Url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"

    Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing

    Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force

    $PlatformTools = "$InstallDir\platform-tools"

    Add-UserPath $PlatformTools

    Write-Host "[OK] Đã cài adb vào $PlatformTools"
}

Install-ADB

Write-Host "[LabDroid] Tải lab_gateway.ps1..."
Invoke-WebRequest -Uri "$RawBase/lab_gateway.ps1" -OutFile "$InstallDir\lab_gateway.ps1" -UseBasicParsing

$BatPath = "$InstallDir\lab.bat"

@"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.labdroid\lab_gateway.ps1"
"@ | Set-Content -Path $BatPath -Encoding ASCII

Add-UserPath $InstallDir

Write-Host ""
Write-Host "[OK] Cài xong."
Write-Host ""
Write-Host "Chạy bằng lệnh:"
Write-Host "  lab"
Write-Host ""
Write-Host "Hoặc:"
Write-Host "  powershell -ExecutionPolicy Bypass -File $InstallDir\lab_gateway.ps1"
Write-Host ""
