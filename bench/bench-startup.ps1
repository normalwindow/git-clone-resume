# One-off startup costs that must stay small, so the TUI does not feel slow to
# open. Run:  powershell -NoProfile -File bench\bench-startup.ps1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "load-gcr.ps1")
. (Get-GcrFunctionBlock -Paths @((Split-Path -Parent $PSScriptRoot) + "\git-clone-resume.tui.ps1")).Block

$script:GcrWidthTable = $null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
[void](Get-GcrWidthTable)
$sw.Stop()
Write-Host ("Get-GcrWidthTable (65536 code points): {0:N1} ms" -f $sw.Elapsed.TotalMilliseconds)

# Second call must be free (cached).
$sw.Restart()
[void](Get-GcrWidthTable)
$sw.Stop()
Write-Host ("Get-GcrWidthTable (cached):            {0:N3} ms" -f $sw.Elapsed.TotalMilliseconds)

$script:GcrEsc = [char]27
$sw.Restart()
$rows = 40
for ($i = 0; $i -lt $rows; $i++) {
    [void](Format-GcrCell -Text ("row {0} 中文内容 example/path/file-{0:d3}.ps1" -f $i) -Width 118)
}
$sw.Stop()
Write-Host ("build {0} padded rows:                        {1:N2} ms" -f $rows, $sw.Elapsed.TotalMilliseconds)
