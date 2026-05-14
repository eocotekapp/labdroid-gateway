$Port = 5555
$AppDir = "$HOME\.labdroid"
$DeviceFile = "$AppDir\devices.txt"

New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

function Banner {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              LabDroid Gateway                ║" -ForegroundColor Cyan
    Write-Host "║              Windows Helper                  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Pause-Lab {
    Write-Host ""
    Read-Host "Nhấn Enter để tiếp tục"
}

function Has-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Ensure-ADB {
    if (Has-Command "adb") {
        Write-Host "[OK] adb đã có." -ForegroundColor Green
        return
    }

    Write-Host "[FAIL] Chưa có adb. Hãy chạy install.ps1 trước." -ForegroundColor Red
    Pause-Lab
}

function Test-Port5555($Ip) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($Ip, $Port, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne(1000, $false)

        if ($success) {
            $client.EndConnect($async)
            $client.Close()
            return $true
        }

        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Connect-ADB-Twice($Target) {
    adb connect $Target | Out-Null
    Start-Sleep -Seconds 1
    adb connect $Target | Out-Null

    $devices = adb devices

    if ($devices -match [regex]::Escape($Target) + "\s+device") {
        Write-Host "OK   $Target" -ForegroundColor Green
    } else {
        Write-Host "FAIL $Target" -ForegroundColor Red
    }
}

function Scan-Custom {
    Banner

    Write-Host "Ví dụ nhập:"
    Write-Host "10.48.154"
    Write-Host "10.48.154 10.48.155"
    Write-Host "192.168.1"
    Write-Host ""

    $Subnets = Read-Host "Nhập subnet cần scan + connect"

    if ([string]::IsNullOrWhiteSpace($Subnets)) {
        Write-Host "Bạn chưa nhập subnet." -ForegroundColor Red
        Pause-Lab
        return
    }

    "" | Set-Content $DeviceFile

    foreach ($Subnet in $Subnets.Split(" ")) {
        foreach ($i in 1..254) {
            $Ip = "$Subnet.$i"

            Start-Job -ScriptBlock {
                param($Ip, $Port, $DeviceFile)

                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    $async = $client.BeginConnect($Ip, $Port, $null, $null)
                    $success = $async.AsyncWaitHandle.WaitOne(1000, $false)

                    if ($success) {
                        $client.EndConnect($async)
                        $client.Close()
                        "$Ip`:$Port" | Add-Content $DeviceFile
                        Write-Output "OPEN $Ip`:$Port"
                    } else {
                        $client.Close()
                    }
                } catch {}
            } -ArgumentList $Ip, $Port, $DeviceFile | Out-Null

            while ((Get-Job -State Running).Count -ge 64) {
                Start-Sleep -Milliseconds 20
            }
        }
    }

    Get-Job | Wait-Job | Receive-Job | ForEach-Object {
        Write-Host $_ -ForegroundColor Green
    }

    Get-Job | Remove-Job

    $targets = Get-Content $DeviceFile | Where-Object { $_ -match ":5555" } | Sort-Object -Unique
    $targets | Set-Content $DeviceFile

    Write-Host ""
    Write-Host "Tìm thấy $($targets.Count) thiết bị mở port 5555." -ForegroundColor Cyan
    Write-Host ""

    foreach ($target in $targets) {
        Connect-ADB-Twice $target
    }

    Write-Host ""
    adb devices | Select-String ":5555"
    Pause-Lab
}

function Quick-Scan {
    Banner

    "" | Set-Content $DeviceFile

    Write-Host "Đang scan nhanh 10.48.154.xxx và 10.48.155.xxx..." -ForegroundColor Yellow
    Write-Host ""

    foreach ($s in 154,155) {
        foreach ($i in 1..254) {
            $Ip = "10.48.$s.$i"

            Start-Job -ScriptBlock {
                param($Ip, $Port, $DeviceFile)

                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    $async = $client.BeginConnect($Ip, $Port, $null, $null)
                    $success = $async.AsyncWaitHandle.WaitOne(1000, $false)

                    if ($success) {
                        $client.EndConnect($async)
                        $client.Close()
                        "$Ip`:$Port" | Add-Content $DeviceFile
                        Write-Output "OPEN $Ip"
                    } else {
                        $client.Close()
                    }
                } catch {}
            } -ArgumentList $Ip, $Port, $DeviceFile | Out-Null
        }
    }

    Get-Job | Wait-Job | Receive-Job | ForEach-Object {
        Write-Host $_ -ForegroundColor Green
    }

    Get-Job | Remove-Job

    $targets = Get-Content $DeviceFile | Where-Object { $_ -match ":5555" } | Sort-Object -Unique
    $targets | Set-Content $DeviceFile

    foreach ($target in $targets) {
        Connect-ADB-Twice $target
    }

    Write-Host ""
    adb devices | Select-String ":5555"
    Pause-Lab
}

function Connect-Saved {
    Banner

    if (!(Test-Path $DeviceFile)) {
        Write-Host "Chưa có danh sách thiết bị." -ForegroundColor Red
        Pause-Lab
        return
    }

    $targets = Get-Content $DeviceFile | Where-Object { $_ -match ":5555" } | Sort-Object -Unique

    foreach ($target in $targets) {
        Connect-ADB-Twice $target
    }

    Write-Host ""
    adb devices | Select-String ":5555"
    Pause-Lab
}

function List-ADB {
    Banner
    adb devices
    Pause-Lab
}

function Open-URL {
    Banner
    $Url = Read-Host "Nhập URL muốn mở"
    if ([string]::IsNullOrWhiteSpace($Url)) { return }

    $devices = adb devices | Select-String "device$" | ForEach-Object {
        ($_ -split "\s+")[0]
    }

    foreach ($d in $devices) {
        adb -s $d shell am start -a android.intent.action.VIEW -d $Url | Out-Null
        Write-Host "OPEN URL -> $d" -ForegroundColor Green
    }

    Pause-Lab
}

function Open-App {
    Banner
    $Pkg = Read-Host "Nhập package app"
    if ([string]::IsNullOrWhiteSpace($Pkg)) { return }

    $devices = adb devices | Select-String "device$" | ForEach-Object {
        ($_ -split "\s+")[0]
    }

    foreach ($d in $devices) {
        adb -s $d shell monkey -p $Pkg -c android.intent.category.LAUNCHER 1 | Out-Null
        Write-Host "OPEN APP -> $d" -ForegroundColor Green
    }

    Pause-Lab
}

function Push-File {
    Banner
    $File = Read-Host "Nhập đường dẫn file/video"
    if (!(Test-Path $File)) {
        Write-Host "Không thấy file." -ForegroundColor Red
        Pause-Lab
        return
    }

    $Name = Split-Path $File -Leaf
    $Remote = "/sdcard/Download/$Name"

    $devices = adb devices | Select-String "device$" | ForEach-Object {
        ($_ -split "\s+")[0]
    }

    foreach ($d in $devices) {
        Write-Host "PUSH -> $d" -ForegroundColor Yellow
        adb -s $d push $File $Remote

        adb -s $d shell am start -a android.intent.action.VIEW -d "file://$Remote" -t "video/*" | Out-Null
        Write-Host "OPEN VIDEO -> $d" -ForegroundColor Green
    }

    Pause-Lab
}

function Menu {
    Ensure-ADB

    while ($true) {
        Banner
        Write-Host "1) Scan + connect subnet tùy chọn"
        Write-Host "2) Scan nhanh 10.48.154 + 10.48.155"
        Write-Host "3) Connect lại danh sách đã scan"
        Write-Host "4) Xem adb devices"
        Write-Host "5) Mở URL hàng loạt"
        Write-Host "6) Mở app hàng loạt"
        Write-Host "7) Push video/file và mở"
        Write-Host "0) Thoát"
        Write-Host ""

        $c = Read-Host "Chọn"

        switch ($c) {
            "1" { Scan-Custom }
            "2" { Quick-Scan }
            "3" { Connect-Saved }
            "4" { List-ADB }
            "5" { Open-URL }
            "6" { Open-App }
            "7" { Push-File }
            "0" { exit }
        }
    }
}

Menu
