param(
    [Parameter(Mandatory=$true)][string]$CaseDirectory,
    [string]$PortName = 'COM9',
    [switch]$ProbeOnly
)

# Solo consultas crc32 y md.l dentro de la copia RAM. Nunca escribe en flash.
# Datos de firmware y logs se guardan fuera del Brain.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Ports
$casePath = [IO.Path]::GetFullPath($CaseDirectory)
$vaultPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($casePath.Equals($vaultPath,[StringComparison]::OrdinalIgnoreCase) -or $casePath.StartsWith($vaultPath + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'La carpeta de adquisición debe estar fuera del Brain.'
}
$null = New-Item -ItemType Directory -Path $casePath -Force
if (-not ('UartCrc32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class UartCrc32 {
    private static readonly uint[] Table = MakeTable();
    private static uint[] MakeTable() {
        var t = new uint[256];
        for (uint n=0;n<256;n++) { uint c=n;for(int k=0;k<8;k++) c=(c&1)!=0?0xedb88320u^(c>>1):c>>1;t[n]=c; }
        return t;
    }
    public static string Compute(byte[] bytes,int offset,int count) {
        uint crc=0xffffffffu;
        for(int i=offset;i<offset+count;i++)crc=Table[(crc^bytes[i])&255]^(crc>>8);
        return (crc^0xffffffffu).ToString("x8");
    }
}
'@
}
$ramBase = 0x81000000L
$imageSize = 0x800000
$expectedCrc = 'b1c224eb'
$sessionStamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$rawPath = Join-Path $casePath ("relectura-$sessionStamp.log")
$journalPath = Join-Path $casePath ("operaciones-$sessionStamp.jsonl")
$statePath = Join-Path $casePath 'estado-relectura.json'
$port = [IO.Ports.SerialPort]::new($PortName,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$port.Handshake = [IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.Encoding = [Text.Encoding]::Latin1
$port.ReadBufferSize = 1048576
$port.ReadTimeout = 150
$port.WriteTimeout = 2000
$raw = $null
$rxBuffer = [byte[]]::new(65536)
$sessionClock = [Diagnostics.Stopwatch]::StartNew()
$completedJobs = 0
$retryCount = 0
$image = $null
$mask = $null

function Invoke-RamCommand([string]$Command) {
    if ($Command -ne '' -and $Command -notmatch '^(crc32|md\.l) 0x[0-9a-f]+ 0x[0-9a-f]+$') { throw 'Comando fuera de la lista permitida.' }
    if ($Command -ne '') {
        $parts = $Command.Split(' ')
        $address = [Convert]::ToInt64($parts[1].Substring(2),16)
        $length = [Convert]::ToInt64($parts[2].Substring(2),16)
        if ($parts[0] -eq 'md.l') { $length *= 4; if ($length -gt 1024) { throw 'Lectura demasiado grande.' } }
        if ($length -le 0 -or $address -lt $ramBase -or $address + $length -gt $ramBase + $imageSize) { throw 'Consulta fuera de la copia RAM.' }
    }
    $port.Write($Command + "`r")
    $reply = [Text.StringBuilder]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 12) {
        try { $count = $port.Read($rxBuffer,0,$rxBuffer.Length) } catch [TimeoutException] { continue }
        if ($count -le 0) { continue }
        $raw.Write($rxBuffer,0,$count)
        [void]$reply.Append([Text.Encoding]::Latin1.GetString($rxBuffer,0,$count))
        if ($reply.ToString() -match '(?:^|[\r\n])U-Boot> ?$') { $raw.Flush(); return $reply.ToString() }
        if ($reply.Length -gt 20000) { throw 'Respuesta inesperadamente larga; se conserva el log.' }
    }
    $raw.Flush()
    throw 'Tiempo agotado esperando el prompt. Se conserva la sesión; no se envía otro comando.'
}

function Get-RamCrc([long]$Address,[int]$Length) {
    for ($attempt=1;$attempt -le 3;$attempt++) {
        $reply = Invoke-RamCommand ('crc32 0x{0:x} 0x{1:x}' -f $Address,$Length)
        $match = [regex]::Match($reply,'CRC32 for ([0-9a-fA-F]{8}) \.\.\. ([0-9a-fA-F]{8}) ==> ([0-9a-fA-F]{8})')
        if ($match.Success -and [Convert]::ToInt64($match.Groups[1].Value,16) -eq $Address -and [Convert]::ToInt64($match.Groups[2].Value,16) -eq $Address+$Length-1) {
            return $match.Groups[3].Value.ToLowerInvariant()
        }
        $script:retryCount++
    }
    throw 'No se ha obtenido un CRC válido en tres consultas.'
}

function Save-Checkpoint([string]$Status,[string]$Phase) {
    if ($null -ne $image) {
        [IO.File]::WriteAllBytes((Join-Path $casePath 'candidato-incompleto.bin'),$image)
        [IO.File]::WriteAllBytes((Join-Path $casePath 'candidato-cobertura.bin'),$mask)
    }
    [ordered]@{status=$Status;phase=$Phase;port=$PortName;completed_jobs=$completedJobs;retries=$retryCount;elapsed_seconds=[math]::Round($sessionClock.Elapsed.TotalSeconds,1);updated_utc=[DateTimeOffset]::UtcNow.ToString('o');raw_log=$rawPath} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Read-VerifiedBlock([int]$Offset,[int]$Length) {
    $address = $ramBase + $Offset
    for ($attempt=1;$attempt -le 5;$attempt++) {
        $reply = Invoke-RamCommand ('md.l 0x{0:x} 0x{1:x}' -f $address,($Length/4))
        $block = [byte[]]::new($Length)
        $seen = [bool[]]::new($Length/4)
        $invalid = $false
        foreach ($line in $reply.Split("`n")) {
            $row = [regex]::Match($line,'^([0-9a-fA-F]{8}): (.*)')
            if (-not $row.Success) { continue }
            $rowAddress = [Convert]::ToInt64($row.Groups[1].Value,16)
            $body = $row.Groups[2].Value
            for ($column=0;$column -lt 4;$column++) {
                $relative = $rowAddress - $address + 4*$column
                if ($relative -lt 0 -or $relative -ge $Length -or $relative%4 -ne 0) { continue }
                $start = 9*$column
                if ($body.Length -lt $start+8) { continue }
                $token = $body.Substring($start,8)
                if ($token -notmatch '^[0-9a-fA-F]{8}$') { continue }
                if ($body.Length -gt $start+8 -and $body[$start+8] -ne ' ' -and $body[$start+8] -ne "`r") { continue }
                $value = [Convert]::ToUInt32($token,16)
                $slot = [int]($relative/4)
                if ($seen[$slot] -and [BitConverter]::ToUInt32($block,[int]$relative) -ne $value) { $invalid = $true }
                [Array]::Copy([BitConverter]::GetBytes($value),0,$block,[int]$relative,4)
                $seen[$slot] = $true
            }
        }
        $missing = $seen.Contains($false)
        if (-not $missing -and -not $invalid) {
            $localCrc = [UartCrc32]::Compute($block,0,$Length)
            $remoteCrc = Get-RamCrc $address $Length
            if ($localCrc -eq $remoteCrc) {
                [Array]::Copy($block,0,$image,$Offset,$Length)
                [Array]::Fill[byte]($mask,1,[int]($Offset/4),[int]($Length/4))
                $script:completedJobs++
                @{offset=$Offset;bytes=$Length;crc32=$localCrc;attempt=$attempt;verified=$true} | ConvertTo-Json -Compress | Add-Content -LiteralPath $journalPath -Encoding utf8
                return
            }
        }
        $script:retryCount++
        Start-Sleep -Milliseconds 30
    }
    throw ('No se ha validado el bloque 0x{0:x}, {1} bytes, después de cinco intentos.' -f $address,$Length)
}

try {
    $port.Open()
    $raw = [IO.File]::Open($rawPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $null = Invoke-RamCommand ''
    $initialCrc = Get-RamCrc $ramBase $imageSize
    Write-Output ('CRC RAM previo: ' + $initialCrc)
    if ($initialCrc -ne $expectedCrc) { throw 'La copia RAM no coincide con la referencia. No se mezclan datos.' }
    if (-not $ProbeOnly) {
        $plan = Get-Content -LiteralPath (Join-Path $casePath 'plan-relectura.json') -Raw | ConvertFrom-Json
        if ($plan.base -ne $ramBase -or $plan.size -ne $imageSize -or $plan.expectedCrc32 -ne $expectedCrc) { throw 'Plan incompatible.' }
        $image = [IO.File]::ReadAllBytes((Join-Path $casePath 'candidato-incompleto.bin'))
        $mask = [IO.File]::ReadAllBytes((Join-Path $casePath 'candidato-cobertura.bin'))
        if ($image.Length -ne $imageSize -or $mask.Length -ne $imageSize/4) { throw 'Estado local incompatible.' }
        Save-Checkpoint 'running' 'repair'
        Write-Output ('Consultas de reparación: ' + $plan.jobs.Count)
        foreach ($job in $plan.jobs) {
            $offset = [int]$job.offset; $length = [int]$job.bytes
            if ($offset%4 -ne 0 -or $length%4 -ne 0 -or $length -le 0 -or $length -gt 1024 -or $offset -lt 0 -or $offset+$length -gt $imageSize) { throw 'Rango de reparación inválido.' }
            $needsRead = $false
            for ($i=$offset/4;$i -lt ($offset+$length)/4;$i++) { if ($mask[$i] -eq 0) { $needsRead=$true;break } }
            if ($needsRead) { Read-VerifiedBlock $offset $length }
            if ($completedJobs%20 -eq 0) { Save-Checkpoint 'running' 'repair'; Write-Output ('Bloques validados: {0}; reintentos: {1}; segundos: {2:n0}' -f $completedJobs,$retryCount,$sessionClock.Elapsed.TotalSeconds) }
        }
        Save-Checkpoint 'running' 'global-crc'
        $localCrc = [UartCrc32]::Compute($image,0,$imageSize)
        if ($localCrc -ne $expectedCrc) {
            Write-Output 'Cobertura cerrada; se buscan errores de datos previos por CRC de bloques de 4 KiB.'
            Save-Checkpoint 'running' 'audit'
            for ($offset=0;$offset -lt $imageSize;$offset+=4096) {
                $remoteCrc = Get-RamCrc ($ramBase+$offset) 4096
                if ($remoteCrc -ne [UartCrc32]::Compute($image,$offset,4096)) {
                    for ($chunk=0;$chunk -lt 4096;$chunk+=1024) { Read-VerifiedBlock ($offset+$chunk) 1024 }
                }
                if (($offset/4096)%64 -eq 0) { Save-Checkpoint 'running' 'audit'; Write-Output ('Auditoría CRC: {0}/2048 páginas; bloques releídos: {1}' -f ($offset/4096),$completedJobs) }
            }
        }
        if ($mask.Contains([byte]0)) { throw 'Quedan palabras sin adquirir.' }
        $localCrc = [UartCrc32]::Compute($image,0,$imageSize)
        $finalRemoteCrc = Get-RamCrc $ramBase $imageSize
        if ($localCrc -ne $expectedCrc -or $finalRemoteCrc -ne $expectedCrc) { throw 'El CRC final no coincide; no se crea firmware validado.' }
        $finalPath = Join-Path $casePath 'flash-original-8MiB.bin'
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($image)).ToLowerInvariant()
        if (Test-Path -LiteralPath $finalPath) {
            if ((Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'Ya existe otra imagen final; se conserva sin sobrescribir.' }
        } else {
            $stream = [IO.File]::Open($finalPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try { $stream.Write($image,0,$image.Length) } finally { $stream.Dispose() }
        }
        $result = [ordered]@{status='verified';bytes=$imageSize;crc32=$localCrc;remote_crc32=$finalRemoteCrc;sha256=$sha;binary=$finalPath;repaired_blocks=$completedJobs;retries=$retryCount;elapsed_seconds=[math]::Round($sessionClock.Elapsed.TotalSeconds,1);raw_log=$rawPath;journal=$journalPath}
        $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $casePath 'adquisicion-verificada.json') -Encoding utf8
        Save-Checkpoint 'verified' 'complete'
        Write-Output ($result | ConvertTo-Json -Compress)
    }
} catch {
    if ($null -ne $image) { Save-Checkpoint 'error' 'retained' }
    throw
} finally {
    if ($raw) { $raw.Dispose() }
    if ($port.IsOpen) { $port.Close() }
    $port.Dispose()
}
