[CmdletBinding()]
param(
    [string]$InputPath = (Join-Path $PSScriptRoot '../SW/ROMs/test/Supersoft_Landmark_1.2.0_AT_5170_64K.BIN'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '../SW/ROMs/test/Supersoft_Landmark_1.2.0_AT_5170_SKIP_PM_V2_64K.BIN')
)

$ErrorActionPreference = 'Stop'
$image = [IO.File]::ReadAllBytes($InputPath)
$sha = [Security.Cryptography.SHA256]::Create().ComputeHash($image)
$shaText = [BitConverter]::ToString($sha).Replace('-', '')
if ($image.Length -ne 65536 -or $shaText -ne 'A8310F83DE0F3E6B71E4A3FF82A01FFE3C3B5A957677AED2FAD17B96BCE2E577') {
    throw "Expected the original 64 KiB Landmark 5170 ROM; size=$($image.Length), SHA-256=$shaText"
}
$inputAbsolute = [IO.Path]::GetFullPath($InputPath)
$outputAbsolute = [IO.Path]::GetFullPath($OutputPath)
if ($inputAbsolute -eq $outputAbsolute) { throw 'Output must not overwrite the original ROM.' }

function Set-MirroredBytes([int]$Address, [byte[]]$Bytes) {
    foreach ($base in 0, 0x8000) {
        [Array]::Copy($Bytes, 0, $image, ($Address -band 0x7FFF) + $base, $Bytes.Length)
    }
}
function Set-NearBranch([int]$Address, [int]$Target, [byte]$Opcode) {
    $relative = ($Target - ($Address + 3)) -band 0xFFFF
    Set-MirroredBytes $Address ([byte[]]($Opcode, ($relative -band 0xFF), ($relative -shr 8)))
}

# V1 only patched 94D8 (later protected-mode RAM); it missed the earlier
# PROTECTED MODE CPU test entered at 8E70 -> A3B3, with LMSW at A596.
# Both tests now go to real-mode display stubs. Neither is reported PASSED.
# Free zero-fill is checked before use; both 32 KiB halves stay identical.
foreach ($base in 0, 0x8000) {
    foreach ($offset in 0x30F0..0x3167) {
        if ($image[$base + $offset] -ne 0) { throw 'Patch cavity is not empty.' }
    }
}
# B100: XOR AX,AX; MOV SS,AX; MOV SP,0800; MOV SI,ACA0
#       MOV DX,B160; MOV BL,07; CALL 9CC0; JMP 8E8F
# 9CC0 is the existing common status renderer, bypassing its PASSED selector.
Set-MirroredBytes 0xB100 ([byte[]](0x33,0xC0,0x8E,0xD0,0xBC,0x00,0x08,0xBE,0xA0,0xAC,0xBA,0x60,0xB1,0xB3,0x07))
Set-NearBranch 0xB10F 0x9CC0 0xE8
Set-NearBranch 0xB112 0x8E8F 0xE9
# B120: same safe real-mode stack, MEMORY AT header, same status renderer.
# Resume at 972D (SYSTEM BIOS), without entering PM or asking the 8042 to reset.
Set-MirroredBytes 0xB120 ([byte[]](0x33,0xC0,0x8E,0xD0,0xBC,0x00,0x08,0xBE,0x1E,0xAE,0xBA,0x60,0xB1,0xB3,0x07))
Set-NearBranch 0xB12F 0x9CC0 0xE8
Set-NearBranch 0xB132 0x972D 0xE9
Set-MirroredBytes 0xB160 ([Text.Encoding]::ASCII.GetBytes("SKIPPED`0"))
Set-NearBranch 0x8E70 0xB100 0xE9
Set-NearBranch 0x94D8 0xB120 0xE9

# ROM tests at 89D4 and 89FF sum even/odd bytes independently in F800:0000.
# Repair each lane in EACH mirror, not just the sum of the full 64 KiB image.
foreach ($lane in 0, 1) {
    $sum = 0
    for ($offset = 0x8000 + $lane; $offset -lt 0x10000; $offset += 2) {
        $sum = ($sum + $image[$offset]) -band 0xFF
    }
    Set-MirroredBytes (0xB0F0 + $lane) ([byte[]]((-$sum) -band 0xFF))
}
foreach ($base in 0, 0x8000) {
    foreach ($lane in 0, 1) {
        $sum = 0
        for ($offset = $base + $lane; $offset -lt $base + 0x8000; $offset += 2) {
            $sum = ($sum + $image[$offset]) -band 0xFF
        }
        if ($sum -ne 0) { throw 'Per-ROM checksum verification failed.' }
    }
}
for ($i = 0; $i -lt 0x8000; $i++) {
    if ($image[$i] -ne $image[$i + 0x8000]) { throw 'ROM mirrors differ.' }
}
$reset = ($image[0xFFF0..0xFFF4] | ForEach-Object { '{0:X2}' -f $_ }) -join '-'
if ($reset -ne 'EA-65-80-00-F0') { throw 'Reset vector changed.' }
# Preserve any existing image unless its content is already exactly V2.
if (Test-Path -LiteralPath $outputAbsolute) {
    $existingSha = (Get-FileHash -LiteralPath $outputAbsolute -Algorithm SHA256).Hash
    $newSha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($image)).Replace('-', '')
    if ($existingSha -ne $newSha) { throw 'Output exists with different content; choose a new OutputPath.' }
}
$parent = Split-Path -Parent $outputAbsolute
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllBytes($outputAbsolute, $image)
$outSha = (Get-FileHash -LiteralPath $outputAbsolute -Algorithm SHA256).Hash
Write-Output "LANDMARK_5170_SKIP_PM_V2_PASS size=65536 lane_checksums=0 mirrors=identical reset=$reset sha256=$outSha"
Write-Output $outputAbsolute
