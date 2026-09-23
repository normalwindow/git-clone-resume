# Runs every TUI test suite and reports a single pass/fail result.
#
#   powershell -NoProfile -File bench\test-all.ps1
#
# Suites:
#   check-bom.ps1        both shipped scripts keep a UTF-8 BOM and parse cleanly
#   test-widthtable.ps1  width table is type-stable, cached, and classifies all
#                        65536 BMP code points exactly like Get-GcrCharWidth
#   test-width.ps1       width/truncate/format helpers match the frozen
#                        pre-optimisation reference on 30 cases + 29 code points
#   test-render.ps1      dashboard and wizard frames are structurally sound
#                        across states and geometries, and frame diffing works
#   test-wizard.ps1      wizard key handling (navigation, toggles, editing,
#                        start/close) and the click hit-map line up with the frame
#   check-native-input.ps1  the console P/Invoke layer compiles, its structs match
#                        Win32, and input never breaks when there is no console
$ErrorActionPreference = "Continue"

$suites = @(
    @{ Name = "encoding + parse"; Script = "check-bom.ps1" }
    @{ Name = "width table"; Script = "test-widthtable.ps1" }
    @{ Name = "width differential"; Script = "test-width.ps1" }
    @{ Name = "render"; Script = "test-render.ps1" }
    @{ Name = "wizard interaction"; Script = "test-wizard.ps1" }
    @{ Name = "native input layer"; Script = "check-native-input.ps1" }
)

$failed = @()
foreach ($s in $suites) {
    Write-Host ""
    Write-Host ("=" * 70)
    Write-Host ("SUITE: {0}  ({1})" -f $s.Name, $s.Script)
    Write-Host ("=" * 70)
    $path = Join-Path $PSScriptRoot $s.Script
    # Clear the inherited value first: a suite that passes without calling `exit`
    # leaves $LASTEXITCODE untouched, so a stale non-zero value would be misread
    # as a failure.
    $global:LASTEXITCODE = 0
    & $path
    if ($LASTEXITCODE -ne 0) { $failed += $s.Name }
}

# Suites that redirect [Console]::Out also drop a results file next to themselves.
# Report it, then remove it so the working tree stays clean.
foreach ($name in @("wizard-results.txt", "native-input-results.txt", "profile-results.txt", "input-results.txt")) {
    $f = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $f)) { continue }
    Write-Host ""
    Write-Host ("--- {0} ---" -f $name)
    Get-Content -LiteralPath $f | ForEach-Object { Write-Host $_ }
    Remove-Item -LiteralPath $f -Force
}

Write-Host ""
Write-Host ("=" * 70)
if ($failed.Count -gt 0) {
    Write-Host ("FAILED suites: {0}" -f ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host "ALL SUITES PASSED" -ForegroundColor Green
