param()
$ErrorActionPreference = 'Continue'
$log = 'C:\PXEServer\dhcp_proxy.log'
function Write-Log($msg) {
    "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Add-Content -Path $log
}
Write-Log "DHCP Proxy starting"
$serverIP   = [byte[]](10,1,4,245)
$bootBIOS   = [System.Text.Encoding]::ASCII.GetBytes('pxelinux.0')
$bootUEFI   = [System.Text.Encoding]::ASCII.GetBytes('Boot/bootx64.efi')
$pxeClient  = [System.Text.Encoding]::ASCII.GetBytes('PXEClient')
$sn         = [System.Text.Encoding]::ASCII.GetBytes('10.1.4.245')

# Parses a DHCP/PXE packet's options and returns whether it's a PXE client request,
# its message type (option 53), and its client architecture (option 93).
function Parse-PxeOptions($buf, $recv) {
    $isPXE      = $false
    $clientArch = 0
    $msgType    = 0
    $i = 240
    while ($i -lt ($recv - 1)) {
        $opt = $buf[$i]
        if ($opt -eq 255) { break }
        if ($opt -eq 0)   { $i++; continue }
        $l = $buf[$i+1]
        if (($i + 2 + $l) -gt $recv) { break }
        if ($opt -eq 53 -and $l -eq 1) { $msgType = $buf[$i+2] }
        if ($opt -eq 60 -and $l -ge 9) {
            if ([System.Text.Encoding]::ASCII.GetString($buf,$i+2,9) -eq 'PXEClient') { $isPXE = $true }
        }
        if ($opt -eq 93 -and $l -eq 2) {
            $clientArch = ($buf[$i+2] -shl 8) -bor $buf[$i+3]
        }
        $i += 2 + $l
    }
    return @{ IsPXE = $isPXE; MsgType = $msgType; ClientArch = $clientArch }
}

# Builds a BOOTREPLY packet (OFFER or ACK) advertising this box as the PXE/TFTP boot server.
function New-PxeReply($buf, $replyType, $bootFile) {
    $r = [byte[]]::new(350)
    $r[0]=2; $r[1]=$buf[1]; $r[2]=$buf[2]; $r[3]=0
    [Array]::Copy($buf,4,$r,4,4)        # xid
    [Array]::Copy($buf,10,$r,10,2)      # flags (preserve broadcast flag)
    [Array]::Copy($serverIP,0,$r,20,4)  # siaddr = TFTP server
    [Array]::Copy($buf,28,$r,28,16)     # chaddr
    [Array]::Copy($sn,0,$r,44,$sn.Length)
    [Array]::Copy($bootFile,0,$r,108,[Math]::Min($bootFile.Length,128))
    $r[236]=99;$r[237]=130;$r[238]=83;$r[239]=99
    $p=240
    $r[$p++]=53;$r[$p++]=1;$r[$p++]=$replyType
    $r[$p++]=54;$r[$p++]=4;$r[$p++]=10;$r[$p++]=1;$r[$p++]=4;$r[$p++]=245
    $r[$p++]=60;$r[$p++]=$pxeClient.Length;$pxeClient|ForEach-Object{$r[$p++]=$_}
    $r[$p++]=66;$r[$p++]=$sn.Length;$sn|ForEach-Object{$r[$p++]=$_}
    $r[$p++]=67;$r[$p++]=$bootFile.Length;$bootFile|ForEach-Object{$r[$p++]=$_}
    $r[$p++]=255
    return ,$r[0..($p-1)]
}

# Port 67: answers the initial PXE-tagged DHCPDISCOVER/DHCPREQUEST broadcasts with boot info.
$sock67 = New-Object System.Net.Sockets.Socket(
    [System.Net.Sockets.AddressFamily]::InterNetwork,
    [System.Net.Sockets.SocketType]::Dgram,
    [System.Net.Sockets.ProtocolType]::Udp)
$sock67.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,[System.Net.Sockets.SocketOptionName]::ReuseAddress,$true)
$sock67.EnableBroadcast = $true
$sock67.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,67))

# Port 4011: some PXE ROMs (e.g. arch 00007/EFI BC) follow up the port-67 exchange with a unicast
# "Boot Server Discover" request straight to the boot server IP we advertised, and refuse to
# proceed to TFTP until they get a unicast "Boot Server Ack" back on this port.
$sock4011 = New-Object System.Net.Sockets.Socket(
    [System.Net.Sockets.AddressFamily]::InterNetwork,
    [System.Net.Sockets.SocketType]::Dgram,
    [System.Net.Sockets.ProtocolType]::Udp)
$sock4011.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,[System.Net.Sockets.SocketOptionName]::ReuseAddress,$true)
$sock4011.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,4011))

Write-Log "Listening on 0.0.0.0:67 and 0.0.0.0:4011 (BIOS->pxelinux.0 | UEFI->Boot/bootx64.efi)"
$buf = [byte[]]::new(1500)

while ($true) {
    try {
        $checkRead = [System.Collections.Generic.List[System.Net.Sockets.Socket]]::new()
        $checkRead.Add($sock67)
        $checkRead.Add($sock4011)
        [System.Net.Sockets.Socket]::Select($checkRead, $null, $null, 500000)

        foreach ($s in $checkRead) {
            $ep = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0))
            $recv = $s.ReceiveFrom($buf,[ref]$ep)
            if ($recv -lt 240) { continue }
            if ($buf[0] -ne 1) { continue }
            if ($buf[236] -ne 99 -or $buf[237] -ne 130 -or $buf[238] -ne 83 -or $buf[239] -ne 99) { continue }

            $parsed = Parse-PxeOptions $buf $recv
            if (-not $parsed.IsPXE) { continue }

            $isUEFI    = ($parsed.ClientArch -eq 6 -or $parsed.ClientArch -eq 7 -or $parsed.ClientArch -eq 9)
            $bootFile  = if ($isUEFI) { $bootUEFI } else { $bootBIOS }
            $archLabel = if ($isUEFI) { "UEFI" } else { "BIOS" }

            if ($s -eq $sock67) {
                # Only respond to DISCOVER (1) and REQUEST (3)
                if ($parsed.MsgType -ne 1 -and $parsed.MsgType -ne 3) { continue }
                $replyType = if ($parsed.MsgType -eq 1) { 2 } else { 5 }
                $typeLabel = if ($parsed.MsgType -eq 1) { "DISCOVER->OFFER" } else { "REQUEST->ACK" }
                Write-Log "PXE $typeLabel from $ep arch=$($parsed.ClientArch) ($archLabel) -> $([System.Text.Encoding]::ASCII.GetString($bootFile))"
                $r = New-PxeReply $buf $replyType $bootFile
                $dest = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast,68)
                $sent = $s.SendTo($r,$r.Length,[System.Net.Sockets.SocketFlags]::None,$dest)
                Write-Log "Sent $sent bytes -> type=$replyType boot=$([System.Text.Encoding]::ASCII.GetString($bootFile))"
            } else {
                # Port 4011: unicast Boot Server Discover -> unicast Boot Server Ack
                Write-Log "PXE BootServer-Discover from $ep arch=$($parsed.ClientArch) ($archLabel) -> $([System.Text.Encoding]::ASCII.GetString($bootFile))"
                $r = New-PxeReply $buf 5 $bootFile
                $sent = $s.SendTo($r,$r.Length,[System.Net.Sockets.SocketFlags]::None,$ep)
                Write-Log "Sent $sent bytes (unicast:4011) -> type=5 boot=$([System.Text.Encoding]::ASCII.GetString($bootFile))"
            }
        }
    } catch {
        Write-Log "Error: $($_.Exception.Message)"
    }
}
