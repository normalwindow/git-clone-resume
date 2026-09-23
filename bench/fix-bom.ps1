# Restores the UTF-8 BOM on the shipped scripts (editors drop it, and Windows
# PowerShell 5.1 then reads them as ANSI), then optionally runs a command.
#
#   powershell -NoProfile -File bench\fix-bom.ps1
#   powershell -NoProfile -File bench\fix-bom.ps1 -Then "bench\test-width.ps1"
param([string]$Then)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$enc = New-Object System.Text.UTF8Encoding($true)
$dec = New-Object System.Text.UTF8Encoding($false, $true)

$targets = @("git-clone-resume.ps1", "git-clone-resume.tui.ps1") +
@(Get-ChildItem -Path (Join-Path $root "bench") -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName.Substring($root.Length + 1) })

foreach ($t in $targets) {
    $p = Join-Path $root $t
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [System.IO.File]::ReadAllBytes($p)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if ($hasBom) { continue }
    try {
        [System.IO.File]::WriteAllText($p, $dec.GetString($b), $enc)
        Write-Host "BOM restored: $t"
    } catch {
        Write-Host "SKIP (not valid UTF-8): $t"
    }
}

if ($Then) {
    Write-Host ""
    Write-Host "=== running $Then ==="
    & (Join-Path $root $Then)
}
