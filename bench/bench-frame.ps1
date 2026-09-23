# End-to-end per-frame cost for Render-GcrTui / Render-GcrTuiWizard.
#
# Replaces [Console]::Out with a memory-backed writer so the render path can be
# exercised and timed exactly as the TUI runs it, in a non-interactive host.
#
# Run with:  powershell -NoProfile -File bench\bench-frame.ps1
$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Write-Host '[b] harness ok'
Initialize-GcrTuiState
Write-Host '[b] state ok'

# --- Stub the console so Out-GcrFrame has somewhere to write -----------------
$script:NullStream = New-Object System.IO.MemoryStream
$script:NullWriter = New-Object System.IO.StreamWriter($script:NullStream, (New-Object System.Text.UTF8Encoding $false))
$script:NullWriter.AutoFlush = $false
[Console]::SetOut($script:NullWriter)

# Force a deterministic geometry so the numbers do not depend on this host.
$script:BenchW = 120
$script:BenchH = 40

function Get-GcrTuiSize {
    return @{ W = $script:BenchW; H = $script:BenchH; DrawW = [Math]::Max(20, $script:BenchW - 1) }
}
function Sync-GcrConsoleBuffer { }
function Test-GcrTuiActive { return ($null -ne $script:GcrTui -and [bool]$script:GcrTui.Active) }
function Test-GcrTuiAvailable { return $true }
function Test-GcrTuiForceQuit { return $false }
function Sync-GcrTuiWindowTitle { }
function Set-GcrTuiTabProgress { param($Percent, $State) }

function Fill-GcrBenchLog {
    param([int]$Count = 400)
    $script:GcrTui.Logs.Clear()
    $dirs = @("src/core", "docs/zh-CN", "third_party/vendor", "assets/images", "tests/integration")
    for ($i = 0; $i -lt $Count; $i++) {
        $p = "{0}/module-{1:d3}/瀹炵幇鏂囦欢-{2:d4}.ps1" -f $dirs[$i % $dirs.Count], ($i % 97), $i
        [void]$script:GcrTui.Logs.Add(@{
                T = (Get-Date).AddSeconds(-1 * ($Count - $i))
                L = @("INFO", "WARN", "OK", "STEP")[$i % 4]
                M = ("checkout ok  " + $p)
            })
    }
}

function Initialize-GcrBenchDash {
    Fill-GcrBenchLog
    $script:GcrTui.Active = $true
    $script:GcrTui.Screen = "dash"
    $script:GcrTui.Phase = "download"
    $script:GcrTui.PhaseDetail = "Receiving objects:  42% (340/802)"
    $script:GcrTui.RepoUrl = "https://github.com/example/some-large-repository.git"
    $script:GcrTui.OutDir = "D:\STRARG\src\some-large-repository"
    $script:GcrTui.Ref = "main"
    $script:GcrTui.Commit = "0123456789abcdef0123456789abcdef01234567"
    $script:GcrTui.Ok = 340
    $script:GcrTui.Total = 802
    $script:GcrTui.Fail = 3
    $script:GcrTui.Bytes = 1288490188
    $script:GcrTui.Speed = 1258291.0
    $script:GcrTui.Rate = 42.5
    $script:GcrTui.Eta = "00:01:20"
    $script:GcrTui.CurrentFile = "src/core/module-042/瀹炵幇鏂囦欢-0042.ps1"
    $script:GcrTui.GitPercent = -1
    $script:GcrTui.LastFrame = @()
    $script:GcrTui.LastFrameW = 0
    $script:GcrTui.LastFrameH = 0
    $script:GcrTui.Tick = 0
}

function Measure-Gcr {
    param([string]$Name, [int]$Iterations, [scriptblock]$Body)
    & $Body | Out-Null                       # warm up / prime LastFrame
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) { & $Body | Out-Null }
    $sw.Stop()
    $per = $sw.Elapsed.TotalMilliseconds / $Iterations
    [pscustomobject]@{
        Name    = $Name
        Iters   = $Iterations
        PerCall = [Math]::Round($per, 3)
        Fps     = [Math]::Round(1000.0 / $per, 0)
    }
}

Write-Host '[b] setup complete'
$results = @()

# 1. Steady state: nothing changed, so Out-GcrFrame should emit zero rows.
Initialize-GcrBenchDash
$results += Measure-Gcr "Render-GcrTui (identical frame)" 100 { Render-GcrTui }

# 2. One new log line per frame: the realistic streaming case.
$script:BenchTick = 0
$results += Measure-Gcr "Render-GcrTui (1 new log line)" 100 {
    $script:BenchTick++
    [void]$script:GcrTui.Logs.Add(@{
            T = Get-Date; L = "INFO"; M = ("checkout ok  batch-{0:d4}" -f $script:BenchTick)
        })
    while ($script:GcrTui.Logs.Count -gt 400) { $script:GcrTui.Logs.RemoveAt(0) }
    Render-GcrTui
}

# 3. Worst case: every row changes (the failed-files view flipping back and forth).
$results += Measure-Gcr "Render-GcrTui (all rows change)" 60 {
    $script:GcrTui.FailView = -not $script:GcrTui.FailView
    Render-GcrTui
}

# 4. The wizard, which re-renders on every keypress.
$st = @{
    Url = "https://github.com/example/repo.git"; OutDir = "D:\src\repo"; OutDirAuto = $false
    Ref = "HEAD"; Language = "zh-CN"; BatchSize = 32; MaxRetries = 8
    Include = ""; Exclude = ""; Depth = ""; Verify = $false; ForceRefetch = $false
    DryRun = $false; Sel = 0; RecentSel = 0; RecentTop = 0; Focus = "form"
    Edit = $false; EditBuf = ""; EditCur = 0; EditField = ""
    Recent = @(
        @{ url = "https://github.com/a/one.git"; outDir = "D:\src\one"; status = "done"; ok = 100; total = 100; updated = (Get-Date).AddMinutes(-5) }
        @{ url = "https://github.com/b/two.git"; outDir = "D:\src\two"; status = "run"; ok = 40; total = 220; updated = (Get-Date).AddHours(-2) }
        @{ url = "https://github.com/c/three.git"; outDir = "D:\src\three"; status = "failed"; ok = 12; total = 90; updated = (Get-Date).AddDays(-1) }
    )
    Scroll = 0; ConfirmQuit = $false; ConfirmClearAll = $false; ConfirmClearOne = $false
    Error = ""; Help = $false
}
$results += Measure-Gcr "Render-GcrTuiWizard" 100 { Render-GcrTuiWizard -St $st }

Write-Host '[b] benchmarks done'
$results | Format-Table -AutoSize

