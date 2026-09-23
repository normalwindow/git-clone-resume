# Encoding guard for the shipped PowerShell scripts.
#
# Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI (GBK on this machine), so
# losing the UTF-8 BOM turns every Chinese string literal into mojibake and the
# file stops parsing. Editing tools routinely drop the BOM, so check it here and
# repair with -Fix.
#
#   powershell -NoProfile -File bench\check-bom.ps1
#   powershell -NoProfile -File bench\check-bom.ps1 -Fix
param([switch]$Fix)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$targets = @("git-clone-resume.ps1", "git-clone-resume.tui.ps1")

$bad = 0
foreach ($name in $targets) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "MISSING: $name"; $bad++; continue }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # Must also be valid UTF-8, BOM or not.
    $valid = $true
    try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { $valid = $false }

    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

    $status = @()
    if (-not $hasBom) { $status += "NO-BOM" }
    if (-not $valid) { $status += "INVALID-UTF8" }
    if ($errors.Count -gt 0) { $status += "PARSE-ERRORS($($errors.Count))" }

    if ($status.Count -eq 0) {
        Write-Host ("OK    {0}  ({1} bytes)" -f $name, $bytes.Length)
        continue
    }

    Write-Host ("BAD   {0}  -> {1}" -f $name, ($status -join ", "))
    $bad++

    if ($Fix -and $valid) {
        $body = $bytes
        if ($hasBom) { $body = $bytes[3..($bytes.Length - 1)] }
        # Decode as UTF-8 and re-emit with a BOM, without touching the text.
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($body)
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($path, $text, $enc)
        Write-Host ("      FIXED: rewrote {0} with a UTF-8 BOM" -f $name)
    }
}

if ($bad -gt 0 -and -not $Fix) {
    Write-Host ""
    Write-Host "Run with -Fix to repair." -ForegroundColor Yellow
    exit 1
}
Write-Host ""
Write-Host "All scripts OK."
