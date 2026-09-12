param([switch]$Vcd)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildPath = Join-Path $repoRoot 'build/at-sdram-capture'
New-Item -ItemType Directory -Force -Path $buildPath | Out-Null
$iverilogPath = (Get-Command iverilog -ErrorAction Stop).Source
$vvpPath = (Get-Command vvp -ErrorAction Stop).Source
$sourceFiles = @(
    'rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv',
    'rtl/spk286_integration/spk286_at_mister_sdram_owner.sv',
    'sim/spk286_integration/spk286_sdram_pin_model.sv',
    'sim/spk286_integration/spk286_at_sdram_capture_tb.sv'
) | ForEach-Object { Join-Path $repoRoot $_ }
Push-Location $buildPath
try {
    foreach ($wiring in 1, 0) {
        $nominalBinary = Join-Path $buildPath "capture_${wiring}_iv"
        & $iverilogPath -g2012 -s spk286_at_sdram_capture_tb "-Pspk286_at_sdram_capture_tb.DQM_FROM_ADDRESS=$wiring" -o $nominalBinary @sourceFiles
        if ($LASTEXITCODE -ne 0) { throw 'Nominal capture test did not elaborate.' }
        $simulationArgs = @($nominalBinary)
        if ($Vcd) { $simulationArgs += '+vcd' }
        $nominalOutput = & $vvpPath @simulationArgs
        $nominalExitCode = $LASTEXITCODE
        $nominalOutput | Set-Content -LiteralPath (Join-Path $buildPath "nominal-$wiring.log") -Encoding ascii
        $nominalOutput
        if ($nominalExitCode -ne 0) { throw 'Nominal SDRAM capture test failed.' }
        if ($Vcd) {
            Move-Item -LiteralPath (Join-Path $buildPath 'at_sdram_capture.vcd') -Destination (Join-Path $buildPath "capture-$wiring.vcd") -Force
        }

        # This is a sensitivity control, not a measured board delay. Delaying
        # forwarded SDRAM clock beyond command arrival changes the edge on which
        # the memory sees READ. A model that holds the last word forever would
        # conceal the resulting late capture. No production clock is changed.
        $skewBinary = Join-Path $buildPath "capture_clock_skew_${wiring}_iv"
        & $iverilogPath -g2012 -s spk286_at_sdram_capture_tb "-Pspk286_at_sdram_capture_tb.DQM_FROM_ADDRESS=$wiring" '-Pspk286_at_sdram_capture_tb.SDRAM_CLOCK_SKEW_NS=4.0' -o $skewBinary @sourceFiles
        if ($LASTEXITCODE -ne 0) { throw 'Clock sensitivity control did not elaborate.' }
        $skewOutput = & $vvpPath $skewBinary
        $skewExitCode = $LASTEXITCODE
        $skewOutput | Set-Content -LiteralPath (Join-Path $buildPath "clock-skew-$wiring.log") -Encoding ascii
        if (($skewExitCode -eq 0) -or (($skewOutput -join "`n") -notmatch 'CAPTURE_TEST read fffff0 expected=5bea actual=zzzz')) {
            throw 'Clock sensitivity control did not detect the expected invalid capture.'
        }
        'AT_SDRAM_CLOCK_SKEW_CONTROL_PASS (artificial +4ns forwarded clock exposes Z read)'
    }
    'AT_SDRAM_CAPTURE_TEST_PASS'
} finally {
    Pop-Location
}
