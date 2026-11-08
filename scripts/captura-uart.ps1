param(
    [string]$PortName = 'COM9',
    [int]$BaudRate = 115200,
    [Parameter(Mandatory = $true)][string]$SessionDirectory,
    [int]$DurationSeconds = 900,
    [switch]$InterruptAutoboot,
    [switch]$QuietReceive
)

# Raw serial data and the control queue stay outside the Brain.
# Transmit is explicit through the queue or the InterruptAutoboot switch.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Ports
$null = New-Item -ItemType Directory -Path $SessionDirectory -Force
$logPath = Join-Path $SessionDirectory 'rx.bin'
$queuePath = Join-Path $SessionDirectory 'commands.jsonl'
$statePath = Join-Path $SessionDirectory 'state.json'
if (-not (Test-Path -LiteralPath $queuePath)) {
    [IO.File]::WriteAllText($queuePath, '')
}
$port = [IO.Ports.SerialPort]::new($PortName, $BaudRate, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$port.Handshake = [IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.ReadTimeout = 200
$port.WriteTimeout = 1000
$log = $null
$received = 0L
$sent = 0L
$queueOffset = 0
$stopRequested = $false
$autobootArmed = [bool]$InterruptAutoboot
$receiveTail = ''
$autobootBurst = $false
$autobootDeadline = [DateTimeOffset]::MinValue
$nextAutobootTx = [DateTimeOffset]::MinValue
$status = 'starting'
$started = [DateTimeOffset]::UtcNow
$lastState = [DateTimeOffset]::MinValue

function Save-SessionState {
    [ordered]@{
        pid = $PID
        port = $PortName
        baud = $port.BaudRate
        framing = '8N1; flow=None; DTR=False; RTS=False'
        status = $status
        started_utc = $started.ToString('o')
        updated_utc = [DateTimeOffset]::UtcNow.ToString('o')
        received_bytes = $received
        sent_bytes = $sent
        autoboot_armed = $autobootArmed
        log_path = $logPath
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
}

try {
    $port.Open()
    $log = [IO.File]::Open($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $status = 'running'
    Save-SessionState
    Write-Output "UART READY: $PortName $BaudRate 8N1; no flow control. Session: $SessionDirectory"
    $buffer = [byte[]]::new(8192)
    while (-not $stopRequested -and ([DateTimeOffset]::UtcNow - $started).TotalSeconds -lt $DurationSeconds) {
        if ($port.BytesToRead -gt 0) {
            $count = $port.Read($buffer, 0, [Math]::Min($buffer.Length, $port.BytesToRead))
            $log.Write($buffer, 0, $count)
            $log.Flush()
            $received += $count
            $display = [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
            $display = [regex]::Replace($display, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '.')
            if (-not $QuietReceive) { [Console]::Write($display) }
            $receiveTail += $display
            if ($autobootArmed -and -not $autobootBurst -and $receiveTail.Contains('U-Boot ')) {
                $autobootBurst = $true
                $autobootDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
                Write-Output "`nUART: bounded Ctrl+C burst armed at U-Boot banner"
            }
            if ($autobootArmed -and ($receiveTail.Contains('Password:') -or $receiveTail.Contains('Starting kernel'))) {
                $autobootArmed = $false
                $autobootBurst = $false
                Write-Output "`nUART: automatic Ctrl+C stopped"
            }
            if ($receiveTail.Length -gt 512) {
                $receiveTail = $receiveTail.Substring($receiveTail.Length - 512)
            }
        }
        if ($autobootBurst -and [DateTimeOffset]::UtcNow -ge $nextAutobootTx) {
            if ([DateTimeOffset]::UtcNow -lt $autobootDeadline) {
                $port.Write([byte[]]@(3), 0, 1)
                $sent++
                $nextAutobootTx = [DateTimeOffset]::UtcNow.AddMilliseconds(40)
            } else {
                $autobootArmed = $false
                $autobootBurst = $false
            }
        }
        $queue = [IO.File]::ReadAllText($queuePath)
        $completeLines = $queue.Split("`n")
        while ($queueOffset -lt $completeLines.Length - 1) {
            $line = $completeLines[$queueOffset].Trim()
            if ($line.Length -gt 0) {
                $command = $line | ConvertFrom-Json
                switch ($command.op) {
                    'tx' {
                        $bytes = [Convert]::FromBase64String($command.data_base64)
                        $port.Write($bytes, 0, $bytes.Length)
                        $sent += $bytes.Length
                        Write-Output "`nUART TX: $($bytes.Length) bytes"
                    }
                    'baud' {
                        $port.BaudRate = [int]$command.value
                        Write-Output "`nUART BAUD: $($port.BaudRate)"
                    }
                    'stop' { $stopRequested = $true }
                    default { throw 'Unsupported control operation' }
                }
            }
            $queueOffset++
        }
        if (([DateTimeOffset]::UtcNow - $lastState).TotalSeconds -ge 2) {
            Save-SessionState
            $lastState = [DateTimeOffset]::UtcNow
        }
        Start-Sleep -Milliseconds 50
    }
    $status = if ($stopRequested) { 'stopped' } else { 'expired' }
} catch {
    $status = 'error'
    Write-Error $_ -ErrorAction Continue
} finally {
    if ($log) { $log.Dispose() }
    if ($port.IsOpen) { $port.Close() }
    Save-SessionState
    $port.Dispose()
    Write-Output "`nUART CLOSED: $status; RX=$received bytes; TX=$sent bytes"
}
