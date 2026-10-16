# Pack the indexed VGA splash into the mode 13h framebuffer and DAC images.
#
# PowerShell equivalent of make_vga_splash_rom.py, for Windows machines without
# Python/Pillow installed. Both scripts produce byte-identical files.
#
# The pixel file is the packed mode 13h framebuffer: one palette index per
# byte, row after row, padded with zeros to 64 KiB. The palette file holds 256
# RGB666 entries, one 18-bit hex word per line (red 17:12, green 11:6, blue 5:0).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$WIDTH             = 320
$HEIGHT            = 200
$FRAMEBUFFER_BYTES = 65536
$PALETTE_ENTRIES   = 256

$ROOT    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PREVIEW = Join-Path $ROOT 'SW\splash_vga_320x200.png'
$PIXELS  = Join-Path $ROOT 'rtl\video\splash_vga_320x200.hex'
$PALETTE = Join-Path $ROOT 'rtl\video\splash_vga_palette.hex'

function Get-Dac6([int]$value) {
    return [int][Math]::Floor(($value * 63 + 127) / 255)
}

$image = New-Object System.Drawing.Bitmap $PREVIEW
try {
    if ($image.PixelFormat -ne [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed) {
        throw "Expected an 8-bit indexed PNG, got $($image.PixelFormat)"
    }
    if ($image.Width -ne $WIDTH -or $image.Height -ne $HEIGHT) {
        throw "Expected ${WIDTH}x${HEIGHT}, got $($image.Width)x$($image.Height)"
    }

    # Read the indices themselves, not colours: equal colours may sit at
    # different palette slots and the raster must see the slot numbers.
    $rect = New-Object System.Drawing.Rectangle 0, 0, $WIDTH, $HEIGHT
    $data = $image.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                            [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    try {
        $raw = New-Object byte[] ($data.Stride * $HEIGHT)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
        $stride = $data.Stride
    } finally {
        $image.UnlockBits($data)
    }
    $entries = $image.Palette.Entries
} finally {
    $image.Dispose()
}

$pixelText = New-Object Text.StringBuilder
for ($y = 0; $y -lt $HEIGHT; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $WIDTH; $x++) {
        [void]$pixelText.AppendFormat('{0:X2}', $raw[$row + $x])
        [void]$pixelText.Append("`n")
    }
}
for ($offset = $WIDTH * $HEIGHT; $offset -lt $FRAMEBUFFER_BYTES; $offset++) {
    [void]$pixelText.Append("00`n")
}

$paletteText = New-Object Text.StringBuilder
for ($index = 0; $index -lt $PALETTE_ENTRIES; $index++) {
    $value = 0
    if ($index -lt $entries.Length) {
        $color = $entries[$index]
        $value = ((Get-Dac6 $color.R) -shl 12) -bor
                 ((Get-Dac6 $color.G) -shl 6)  -bor
                  (Get-Dac6 $color.B)
    }
    [void]$paletteText.AppendFormat('{0:X5}', $value)
    [void]$paletteText.Append("`n")
}

$ascii = New-Object Text.ASCIIEncoding
[IO.File]::WriteAllText($PIXELS, $pixelText.ToString(), $ascii)
[IO.File]::WriteAllText($PALETTE, $paletteText.ToString(), $ascii)
