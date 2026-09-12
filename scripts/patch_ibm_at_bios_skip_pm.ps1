<#
Create a development-only IBM PC/AT 5170 BIOS variant that skips the
protected-mode POST phases which the current SPK286 does not yet implement.

The original interleaved BIOS is never modified.  The patch keeps the normal
AT POST flow, reports 640 KiB of conventional memory, skips the two protected
mode memory phases, and skips POST3's protected-mode instruction tests as if
they had passed.
#>
[CmdletBinding()]
param(
    [string]$InputPath = 'D:\GitHub\PCAT-286_MiSTer\SW\ROMs\test\IBM_AT_5170_15NOV85_62X082x_64K.BIN',
    [string]$OutputPath = 'D:\GitHub\PCAT-286_MiSTer\SW\ROMs\test\IBM_AT_5170_15NOV85_SKIP_PM_64K.BIN'
)

$ErrorActionPreference = 'Stop'

$expectedInputSha256 = '70B44796F0B259730F34DFA2301445BEA9BFAB0C0F7451DC6F64CF3B32FE9387'
$patches = @(
    @{ Offset = 0x0755; Expected = [byte[]](0xB8, 0x8F, 0x01); Replacement = [byte[]](0xB8, 0x80, 0x02); Description = 'load 640 KiB conventional-memory size' },
    @{ Offset = 0x0758; Expected = [byte[]](0xE8, 0x04, 0x12); Replacement = [byte[]](0xA3, 0x13, 0x00); Description = 'store conventional-memory size in the BDA' },
    @{ Offset = 0x075B; Expected = [byte[]](0xBC, 0x00, 0x00); Replacement = [byte[]](0xE9, 0x30, 0x02); Description = 'skip protected-mode/base-memory POST to F000:098E' },
    @{ Offset = 0x0DED; Expected = [byte[]](0xB8, 0x8F, 0x02); Replacement = [byte[]](0xE9, 0xC4, 0x02); Description = 'skip protected-mode/extended-memory POST to F000:10B4' },
    @{ Offset = 0x1675; Expected = [byte[]](0xE8, 0x01, 0x03); Replacement = [byte[]](0xE9, 0x60, 0xFA); Description = 'skip POST3 protected-mode tests to F000:10D8 as passed' },
    @{ Offset = 0x4BE0; Expected = [byte[]](0xCC); Replacement = [byte[]](0x06); Description = 'checksum compensation in unused ROM padding'
    }
)

$inputFullPath = [IO.Path]::GetFullPath($InputPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.File]::Exists($inputFullPath)) {
    throw "Input ROM not found: $inputFullPath"
}

$inputHash = (Get-FileHash -LiteralPath $inputFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($inputHash -ne $expectedInputSha256) {
    throw "Unexpected input ROM SHA-256 ($inputHash). Refusing to patch a different image."
}

$bytes = [IO.File]::ReadAllBytes($inputFullPath)
if ($bytes.Length -ne 65536) {
    throw "Unexpected input ROM size: $($bytes.Length) bytes (expected 65536)."
}

foreach ($patch in $patches) {
    $offset = $patch.Offset
    $expectedBytes = $patch.Expected
    for ($i = 0; $i -lt $expectedBytes.Length; $i++) {
        if ($bytes[$offset + $i] -ne $expectedBytes[$i]) {
            $got = ($bytes[$offset..($offset + $expectedBytes.Length - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $expected = ($expectedBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            throw ('Unexpected bytes at ROM offset 0x{0:X4}: got {1}, expected {2}.' -f $offset, $got, $expected)
        }
    }
    for ($i = 0; $i -lt $patch.Replacement.Length; $i++) {
        $bytes[$offset + $i] = $patch.Replacement[$i]
    }
}

$sum8 = 0
foreach ($value in $bytes) {
    $sum8 = ($sum8 + $value) -band 0xFF
}
if ($sum8 -ne 0) {
    throw ('Patched ROM checksum is not zero: 0x{0:X2}' -f $sum8)
}
$resetVector = [BitConverter]::ToString($bytes[0xFFF0..0xFFF4])
if ($resetVector -ne 'EA-5B-E0-00-F0') {
    throw "Unexpected reset vector after patch: $resetVector"
}

$outputDirectory = Split-Path -Parent $outputFullPath
if (-not [IO.Directory]::Exists($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
if ([IO.File]::Exists($outputFullPath)) {
    $existingHash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $newHash = ([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)
    $newHashText = ([BitConverter]::ToString($newHash) -replace '-', '').ToUpperInvariant()
    if ($existingHash -ne $newHashText) {
        throw "Refusing to overwrite an existing different output ROM: $outputFullPath"
    }
    Write-Output "Already present: $outputFullPath"
} else {
    [IO.File]::WriteAllBytes($outputFullPath, $bytes)
    Write-Output "Created: $outputFullPath"
}

$outputHash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Output "size=$($bytes.Length)"
Write-Output "sha256=$outputHash"
Write-Output ('sum8=0x{0:X2}' -f $sum8)
Write-Output "reset_vector=$resetVector"
foreach ($patch in $patches) {
    $oldBytes = ($patch.Expected | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $newBytes = ($patch.Replacement | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    Write-Output ('patch 0x{0:X4}: {1} -> {2} ({3})' -f $patch.Offset, $oldBytes, $newBytes, $patch.Description)
}
