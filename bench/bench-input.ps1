# Input-latency benchmark.
#
# Reproduces the "hold the down arrow and the highlight keeps moving after you let
# go" complaint: Windows auto-repeat delivers key events far faster than a
# PowerShell frame can be composed, so if every event forces its own repaint the
# backlog outlives the keypress.
#
# The benchmark seeds the real pending-input queue with a burst that a held key
# would produce, then measures how long the queue takes to drain and how many
# frames are painted getting there.
#
# Run:  powershell -NoProfile -File bench\bench-input.ps1
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Initialize-GcrTuiState

# Results go to a file: this benchmark redirects [Console]::Out to capture frames,
# so console writes made after that point are not visible on the terminal.
$out = New-Object System.Collections.Generic.List[string]
function Say { param([string]$T) [void]$out.Add($T); Write-Host $T }

# --- Frame capture -----------------------------------------------------------
$script:Cap = New-Object System.IO.MemoryStream
$script:CapWriter = New-Object System.IO.StreamWriter($script:Cap, (New-Object System.Text.UTF8Encoding($false)))
$script:CapWriter.AutoFlush = $false
[Console]::SetOut($script:CapWriter)

$script:W = 120
$script:H = 40
$script:FrameCount = 0
$script:RealRender = ${function:Render-GcrTuiWizard}

function Get-GcrTuiSize { return @{ W = $script:W; H = $script:H; DrawW = [Math]::Max(20, $script:W - 1) } }
function Sync-GcrConsoleBuffer { }
function Test-GcrTuiActive { return $true }
function Test-GcrTuiAvailable { return $true }
function Test-GcrTuiForceQuit { return $false }
function Sync-GcrTuiWindowTitle { }
function Set-GcrTuiTabProgress { param($Percent, $State) }
function Enable-GcrMouse { return $false }
function Disable-GcrMouse { }
function Get-GcrClipboardText { return "" }

# Count paints without changing what a paint does.
function Render-GcrTuiWizard {
    param($St)
    $script:FrameCount++
    & $script:RealRender -St $St
}

$script:GcrTui.Active = $true
$script:GcrTui.Box = Get-GcrAsciiBox
$script:GcrTui.Screen = "wizard"
$script:GcrTui.Width = $script:W
$script:GcrTui.Height = $script:H

function New-GcrBenchState {
    return @{
        Url = "https://github.com/example/repo.git"; OutDir = "D:\src\repo"; OutDirAuto = $false
        Ref = "HEAD"; Language = "zh-CN"; BatchSize = 32; MaxRetries = 8
        Include = ""; Exclude = ""; Depth = ""; Verify = $false; ForceRefetch = $false
        DryRun = $false; Sel = 0; RecentSel = 0; RecentTop = 0; Focus = "form"
        Edit = $false; EditBuf = ""; EditCur = 0; EditField = ""
        Recent = @(
            @{ url = "https://github.com/a/one.git"; outDir = "D:\src\one"; status = "done"; ok = 100; total = 100; updated = (Get-Date).AddMinutes(-5) }
        )
        Scroll = 0; ConfirmQuit = $false; ConfirmClearAll = $false; ConfirmClearOne = $false
        Error = ""; Help = $false
    }
}

function New-GcrBenchArrow {
    # One auto-repeat record for DownArrow, as Convert-GcrKeyEvent would produce.
    return New-Object System.ConsoleKeyInfo([char]0, [ConsoleKey]::DownArrow, $false, $false, $false)
}

# A key-repeat burst as Windows delivers it: ~30 events/second.
$repeatHz = 30
$burstSeconds = 2
$burst = [int]($repeatHz * $burstSeconds)

Say ("Hold DownArrow for {0}s -> ~{1} queued events (Windows auto-repeat ~{2}/s)" -f $burstSeconds, $burst, $repeatHz)
Say ""
Say "The burst is pre-seeded into the real pending-input queue and the console"
Say "reader is bypassed, so what is measured is the cost of *processing* the"
Say "backlog - which is what the user actually waits on. In production the reader"
Say "appends new arrivals to this same queue and the loop applies them in one pass,"
Say "so seeding the whole burst exercises an identical code path."
Say ""

# Takes everything currently queued. Equivalent to Receive-GcrTuiInputBatch for a
# queue that is already full, without reaching for the real console.
function Get-GcrQueuedBatch {
    param([System.Collections.Generic.List[object]]$Sink)
    while ($script:GcrPendingInput.Count -gt 0) {
        $item = $script:GcrPendingInput[0]
        $script:GcrPendingInput.RemoveAt(0)
        [void]$Sink.Add($item)
    }
    return $Sink.Count
}

function Measure-GcrDrain {
    param([int]$EventCount, [int]$RenderEvery)

    $st = New-GcrBenchState
    $script:FrameCount = 0
    $script:GcrPendingInput.Clear()
    for ($i = 0; $i -lt $EventCount; $i++) { [void]$script:GcrPendingInput.Add((New-GcrBenchArrow)) }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $handled = 0
    if ($RenderEvery -le 0) {
        # Batched: apply everything, then paint once (what the wizard now does).
        $batch = New-Object System.Collections.Generic.List[object]
        [void](Get-GcrQueuedBatch -Sink $batch)
        foreach ($ev in $batch) { $null = Invoke-GcrWizardEvent -St $st -K $ev; $handled++ }
        Render-GcrTuiWizard -St $st      # the single paint that follows the batch
    } else {
        # Per-event: paint after every N events (the old behaviour was N == 1).
        while ($script:GcrPendingInput.Count -gt 0) {
            $ev = $script:GcrPendingInput[0]
            $script:GcrPendingInput.RemoveAt(0)
            $null = Invoke-GcrWizardEvent -St $st -K $ev
            $handled++
            if (($handled % $RenderEvery) -eq 0) { Render-GcrTuiWizard -St $st }
        }
    }
    $sw.Stop()

    [pscustomobject]@{
        Mode         = if ($RenderEvery -le 0) { "batched (now)" } else { "repaint per $RenderEvery event(s)" }
        Events       = $handled
        Frames       = $script:FrameCount
        DrainMs      = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        MsPerEvent   = [Math]::Round($sw.Elapsed.TotalMilliseconds / [Math]::Max(1, $handled), 3)
    }
}

# Warm up so JIT cost is not attributed to either mode.
$null = Measure-GcrDrain 5 0

$results = @()
$results += Measure-GcrDrain $burst 0     # batched, one paint
$results += Measure-GcrDrain $burst 1     # legacy: a paint per event
$results += Measure-GcrDrain $burst 4     # a middle ground

$results | Format-Table -AutoSize | Out-String | ForEach-Object { Say $_ }

$batched = $results[0]
$legacy = $results[1]
Say ("Queued burst of {0} events:" -f $burst)
Say ("  batched : {0,7:N1} ms to fully drain, {1} paint(s)" -f $batched.DrainMs, $batched.Frames)
Say ("  legacy  : {0,7:N1} ms to fully drain, {1} paint(s)" -f $legacy.DrainMs, $legacy.Frames)
if ($batched.DrainMs -gt 0) {
    Say ("  speedup : {0:N1}x faster to drain; the final state appears {1:N0} ms sooner" -f `
            ($legacy.DrainMs / $batched.DrainMs), ($legacy.DrainMs - $batched.DrainMs))
}
Say ""
Say ("Reference: one full wizard paint costs about {0:N1} ms." -f ($legacy.DrainMs / [Math]::Max(1, $legacy.Frames)))

$out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "input-results.txt") -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
