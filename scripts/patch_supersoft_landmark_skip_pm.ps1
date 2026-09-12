[CmdletBinding()]
param(
    [string]$InputPath = 'D:\GitHub\PCAT-286_MiSTer\SW\ROMs\test\Supersoft_Landmark_1.2.0_AT_5170_64K.BIN',
    [string]$OutputPath = 'D:\GitHub\PCAT-286_MiSTer\SW\ROMs\test\Supersoft_Landmark_1.2.0_AT_5170_SKIP_PM_64K.BIN'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Landmark input ROM not found: $InputPath"
}

$image = [IO.File]::ReadAllBytes($InputPath)
if ($image.Length -ne 65536) {
    throw "Expected a 64 KiB interleaved ROM, got $($image.Length) bytes"
}

$sha = [Security.Cryptography.SHA256]::Create().ComputeHash($image)
$shaText = [BitConverter]::ToString($sha).Replace('-', '')
$expectedSha = 'A8310F83DE0F3E6B71E4A3FF82A01FFE3C3B5A957677AED2FAD17B96BCE2E577'
if ($shaText -ne $expectedSha) {
    throw "Unexpected Landmark input SHA-256: $shaText"
}

# The AT diagnostic ROM contains the same 32 KiB code image in both halves.
# At 14D8h it enters 286 protected mode.  Replace only that entry with a
# near jump to the ROM's existing CMOS-shutdown/reset path at 171Ah.  After
# the warm reset, the original startup code resumes at the PM-test continuation
# instead of executing unsupported protected-mode instructions.
$patchOffsets = @(0x14D8, 0x94D8)
$patchBytes = [byte[]](0xE9, 0x3F, 0x02) # jmp +023Fh: 14D8h -> 171Ah (same in mirror)
foreach ($offset in $patchOffsets) {
    if ($image[$offset] -ne 0xFA -or
        $image[$offset + 1] -ne 0x8C -or
        $image[$offset + 2] -ne 0xC8) {
        throw ('Unexpected PM entry bytes at 0x{0:X4}' -f $offset)
    }
    for ($i = 0; $i -lt $patchBytes.Length; $i++) {
        $image[$offset + $i] = $patchBytes[$i]
    }
}

# Keep the standard 8-bit ROM checksum valid.  The two mirrored bytes below
# are inside the original long zero-fill region and are deliberately adjusted
# equally so both 32 KiB copies remain identical.
$checksumOffsets = @(0x30EB, 0xB0EB)
foreach ($offset in $checksumOffsets) {
    if ($image[$offset] -ne 0x00) {
        throw ('Checksum compensation byte is not zero at 0x{0:X4}' -f $offset)
    }
}
$sum = 0
foreach ($byte in $image) { $sum = ($sum + $byte) -band 0xFF }
$correction = (0 - $sum) -band 0xFF
if (($correction -band 1) -ne 0) {
    throw ('Checksum correction is not evenly distributable across mirrors: 0x{0:X2}' -f $correction)
}
$perMirrorCorrection = $correction / 2
foreach ($offset in $checksumOffsets) {
    $image[$offset] = [byte](($image[$offset] + $perMirrorCorrection) -band 0xFF)
}

$sum = 0
foreach ($byte in $image) { $sum = ($sum + $byte) -band 0xFF }
if ($sum -ne 0) {
    throw ('Patched Landmark checksum is not zero: 0x{0:X2}' -f $sum)
}
foreach ($offset in $patchOffsets) {
    if ($image[$offset] -ne 0xE9 -or
        $image[$offset + 1] -ne 0x3F -or
        $image[$offset + 2] -ne 0x02) {
        throw ('PM entry patch verification failed at 0x{0:X4}' -f $offset)
    }
}
$reset = ($image[0xFFF0..0xFFF4] | ForEach-Object { '{0:X2}' -f $_ }) -join '-'
if ($reset -ne 'EA-65-80-00-F0') {
    throw "Reset vector changed unexpectedly: $reset"
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
[IO.File]::WriteAllBytes($OutputPath, $image)

$outSha = [Security.Cryptography.SHA256]::Create().ComputeHash($image)
$outShaText = [BitConverter]::ToString($outSha).Replace('-', '')
Write-Output ('LANDMARK_5170_SKIP_PM_PASS size={0} sum8=0x{1:X2} correction=0x{2:X2} reset={3} sha256={4}' -f $image.Length, $sum, $correction, $reset, $outShaText)
