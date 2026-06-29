# FDLTCC Post-Install Script
# Runs on first logon after Windows 11 Pro is installed
# Collects specs, runs disk/battery tests, renames computer, copies tools

$ErrorActionPreference = 'Continue'
$log = 'C:\temp\setup.log'
$ts = { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]" }

function Write-Log($msg) {
    "$(&$ts) $msg" | Tee-Object -FilePath $log -Append | Write-Host
}

New-Item -ItemType Directory -Path C:\temp -Force | Out-Null
Write-Log "Post-install script started"

# ── 1. Rename computer to FDL-{SerialNumber} ──────────────────────────────
$serial = (Get-WmiObject Win32_BIOS).SerialNumber.Trim()
$newName = "FDL-$serial"
if ($env:COMPUTERNAME -ne $newName) {
    Rename-Computer -NewName $newName -Force -ErrorAction SilentlyContinue
    Write-Log "Renamed computer to $newName"
} else {
    Write-Log "Computer already named $newName"
}

# ── 2. System Specifications ───────────────────────────────────────────────
Write-Log "Collecting system specs..."
$cs   = Get-WmiObject Win32_ComputerSystem
$bios = Get-WmiObject Win32_BIOS
$cpu  = Get-WmiObject Win32_Processor | Select-Object -First 1
$os   = Get-WmiObject Win32_OperatingSystem
$ram  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
$disks = Get-PhysicalDisk | Select-Object FriendlyName,
    @{N='SizeGB';E={[math]::Round($_.Size/1GB,0)}}

$specs = @"
FDLTCC Machine Specifications
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer: $($env:COMPUTERNAME)
Manufacturer: $($cs.Manufacturer)
Model: $($cs.Model)
Serial: $($bios.SerialNumber)
OS: $($os.Caption) $($os.Version)
RAM: $ram GB
CPU: $($cpu.Name)
"@
$disks | ForEach-Object { $specs += "`nDisk: $($_.FriendlyName) $($_.SizeGB) GB" }
$specs | Out-File -FilePath C:\temp\specs.txt -Encoding UTF8
Write-Log "Wrote C:\temp\specs.txt"

# ── 3. Battery Health Test ─────────────────────────────────────────────────
Write-Log "Running battery health test..."
$batteryReport = @"
FDLTCC Detailed Battery Health Report
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer: $($env:COMPUTERNAME)

CHARGE LEVEL = how full the battery is right now (fuel gauge).
BATTERY HEALTH = max capacity today vs capacity when new (wear test).

"@

# Generate Windows battery report XML for detailed data
$battXml = "C:\temp\battery-report.xml"
powercfg /batteryreport /xml /output $battXml 2>$null

$batteries = Get-WmiObject Win32_Battery
if ($batteries) {
    foreach ($b in $batteries) {
        $chargeLevel = if ($b.EstimatedChargeRemaining) { "$($b.EstimatedChargeRemaining)%" } else { "Unknown" }
        $status = switch ($b.BatteryStatus) {
            1 { "Discharging" } 2 { "AC Power" } 3 { "Fully Charged" }
            4 { "Low" } 5 { "Critical" } 6 { "Charging" }
            7 { "Charging/High" } 8 { "Charging/Low" } 9 { "Charging/Critical" }
            default { "Unknown" }
        }
        $batteryReport += "Battery: $($b.Name)`n"
        $batteryReport += "Status: $status`n"
        $batteryReport += "Charge Level: $chargeLevel`n"

        if ($b.DesignCapacity -and $b.FullChargeCapacity -and $b.DesignCapacity -gt 0) {
            $health = [math]::Round(($b.FullChargeCapacity / $b.DesignCapacity) * 100, 1)
            $batteryReport += "Battery Health: $health% (Full=$($b.FullChargeCapacity) mWh / Design=$($b.DesignCapacity) mWh)`n"
        }

        # Try detailed data from battery report XML
        if (Test-Path $battXml) {
            try {
                [xml]$bx = Get-Content $battXml
                $ns = $bx.BatteryReport.Batteries.Battery
                if ($ns) {
                    $batteryReport += "Cycle Count: $($ns.CycleCount)`n"
                    $batteryReport += "Design Capacity: $($ns.DesignCapacity) mWh`n"
                    $batteryReport += "Full Charge Capacity: $($ns.FullChargeCapacity) mWh`n"
                }
            } catch {}
        }
    }
} else {
    $batteryReport += "No battery detected. This may be a desktop or the battery is not reporting to Windows.`n"
}

# Also run powercfg HTML report
powercfg /batteryreport /output C:\temp\battery-report.html 2>$null

$batteryReport | Out-File -FilePath C:\temp\battery-health.txt -Encoding UTF8
Write-Log "Wrote C:\temp\battery-health.txt"

# ── 4. Disk Health Test ────────────────────────────────────────────────────
Write-Log "Running disk health test..."
$diskReport = @"
FDLTCC Detailed Disk Health Report
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer: $($env:COMPUTERNAME)

=== Physical Disks ===

"@

$physDisks = Get-PhysicalDisk
foreach ($d in $physDisks) {
    $diskReport += "Friendly name: $($d.FriendlyName)`n"
    $diskReport += "Model: $($d.Model)`n"
    $diskReport += "Serial number: $($d.SerialNumber)`n"
    $diskReport += "Media type: $($d.MediaType)`n"
    $diskReport += "Bus type: $($d.BusType)`n"
    $diskReport += "Size: $([math]::Round($d.Size/1GB,1)) GB`n"
    $diskReport += "Health status: $($d.HealthStatus)`n"
    $diskReport += "Operational status: $($d.OperationalStatus)`n"

    # SMART reliability data
    try {
        $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop
        $diskReport += "--- Reliability / SMART counters ---`n"
        if ($rel.Temperature) { $diskReport += "Temperature: $($rel.Temperature) C`n" }
        if ($d.MediaType -eq 'SSD' -and $rel.Wear -ne $null) {
            $diskReport += "Wear (SSD): $($rel.Wear)%`n"
        }
        if ($rel.ReadLatencyMax) { $diskReport += "Read latency max (ms): $($rel.ReadLatencyMax)`n" }
        if ($rel.WriteLatencyMax) { $diskReport += "Write latency max (ms): $($rel.WriteLatencyMax)`n" }
    } catch {}

    # Overall assessment
    $assessment = if ($d.HealthStatus -eq 'Healthy') { 'Good' } else { 'CHECK REQUIRED' }
    $diskReport += "Assessment: $assessment`n`n"
}

$diskReport += "=== Volumes ===`n"
Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
    $free = [math]::Round($_.SizeRemaining/1GB,1)
    $total = [math]::Round($_.Size/1GB,1)
    $diskReport += "$($_.DriveLetter): $free GB free of $total GB | FileSystem=$($_.FileSystem) | Health=$($_.HealthStatus)`n"
}

$diskReport += "`n=== Partitions ===`n"
Get-Disk | ForEach-Object {
    $disk = $_
    Get-Partition -DiskNumber $disk.Number | ForEach-Object {
        $size = [math]::Round($_.Size/1GB,1)
        $diskReport += "Disk $($disk.Number) Partition $($_.PartitionNumber): $size GB | Type=$($_.Type) | Letter=$($_.DriveLetter) | Boot=$($_.IsActive)`n"
    }
}

$diskReport | Out-File -FilePath C:\temp\disk-health.txt -Encoding UTF8
Write-Log "Wrote C:\temp\disk-health.txt"

# ── 5. Health Summary ──────────────────────────────────────────────────────
$summary = @"
FDLTCC Health Summary
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer: $($env:COMPUTERNAME)

Detailed reports:
  C:\temp\battery-health.txt
  C:\temp\battery-report.html
  C:\temp\disk-health.txt

--- Battery summary ---
$(if ($batteries) { "Battery detected: $(($batteries | Select-Object -First 1).Name)" } else { "No battery detected (desktop)" })

--- Disk summary ---
$(Get-PhysicalDisk | ForEach-Object { "$($_.FriendlyName): $($_.HealthStatus)" } | Out-String)
$(Get-Volume | Where-Object {$_.DriveLetter} | ForEach-Object { "$($_.DriveLetter): $([math]::Round($_.SizeRemaining/1GB,1)) GB free of $([math]::Round($_.Size/1GB,1)) GB" } | Out-String)
"@
$summary | Out-File -FilePath C:\temp\health.txt -Encoding UTF8
Write-Log "Wrote C:\temp\health.txt (summary)"

# ── 6. Copy results to PXE server share ───────────────────────────────────
Write-Log "Copying results to network share..."
try {
    $dest = "\\10.1.4.245\shared\results\$($env:COMPUTERNAME)"
    New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null
    Copy-Item C:\temp\*.txt $dest -Force
    Copy-Item C:\temp\*.html $dest -Force -ErrorAction SilentlyContinue
    Write-Log "Copied results to $dest"
} catch {
    Write-Log "Could not copy to share: $($_.Exception.Message)"
}

# ── 7. Disable auto-logon ─────────────────────────────────────────────────
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "AutoAdminLogon" -ErrorAction SilentlyContinue
Write-Log "Disabled auto-logon"

Write-Log "Post-install complete. Computer will restart in 30 seconds."
Start-Sleep -Seconds 30
Restart-Computer -Force
