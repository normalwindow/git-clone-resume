# Runs a benchmark script and reports any terminating error with a stack trace,
# so a silent failure is never mistaken for "no output".
param([Parameter(Mandatory = $true)][string]$Script)

$ErrorActionPreference = "Stop"
try {
    & $Script
    Write-Host ""
    Write-Host "[runner] completed OK"
} catch {
    Write-Host ""
    Write-Host "[runner] FAILED: $($_.Exception.Message)"
    Write-Host "[runner] at: $($_.InvocationInfo.PositionMessage)"
    Write-Host "[runner] stack:"
    Write-Host $_.ScriptStackTrace
    exit 1
}
