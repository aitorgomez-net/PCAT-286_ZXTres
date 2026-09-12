[CmdletBinding()]
param(
    [string]$OutputPath = 'D:\GitHub\PCAT-286_MiSTer\SW\ROMs\test\Supersoft_Landmark_1.2.0_AT_5170_64K.BIN'
)

$ErrorActionPreference = 'Stop'

$u27Url = 'https://www.minuszerodegrees.net/supersoft_landmark/5170_EVEN_LOW_U27_27256.bin'
$u47Url = 'https://www.minuszerodegrees.net/supersoft_landmark/5170_ODD_HIGH_U47_27256.bin'

$u27 = (New-Object Net.WebClient).DownloadData($u27Url)
$u47 = (New-Object Net.WebClient).DownloadData($u47Url)
if ($u27.Length -ne 32768 -or $u47.Length -ne 32768) {
    throw "Unexpected Landmark image size: U27=$($u27.Length), U47=$($u47.Length)"
}

$image = New-Object byte[] 65536
for ($i = 0; $i -lt 32768; $i++) {
    $image[2 * $i] = $u27[$i]
    $image[2 * $i + 1] = $u47[$i]
}

$sum = 0
foreach ($byte in $image) { $sum = ($sum + $byte) -band 0xFF }
if ($sum -ne 0) { throw ('Interleaved Landmark checksum is not zero: 0x{0:X2}' -f $sum) }

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
[IO.File]::WriteAllBytes($OutputPath, $image)

$sha = [Security.Cryptography.SHA256]::Create().ComputeHash($image)
$shaText = [BitConverter]::ToString($sha).Replace('-', '')
$reset = ($image[0xFFF0..0xFFF4] | ForEach-Object { '{0:X2}' -f $_ }) -join '-'
Write-Output ('LANDMARK_5170_FETCH_PASS size={0} sum8=0x{1:X2} reset={2} sha256={3}' -f $image.Length, $sum, $reset, $shaText)
