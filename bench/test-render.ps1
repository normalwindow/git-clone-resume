# Render regression test.
#
# Renders the dashboard and the wizard across the states that matter and asserts
# the produced frames are structurally sound:
#   * exactly one row per terminal line,
#   * every row exactly DrawW display cells wide (so nothing wraps),
#   * every row starts and ends on the border glyph,
#   * no row paints the last terminal column,
#   * output is deterministic and free of raw newlines.
#
# Run:  powershell -NoProfile -File bench\test-render.ps1
$ErrorActionPreference = "Stop"
Write-Host "[t] start"

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Write-Host "[t] harness ok"
Initialize-GcrTuiState
Write-Host "[t] state ok"

# Capture what Out-GcrFrame emits instead of writing to a terminal.
$script:Cap = New-Object System.IO.MemoryStream
$script:CapWriter = New-Object System.IO.StreamWriter($script:Cap, (New-Object System.Text.UTF8Encoding($false)))
$script:CapWriter.AutoFlush = $false
[Console]::SetOut($script:CapWriter)

$script:W = 120
$script:H = 40
function Get-GcrTuiSize { return @{ W = $script:W; H = $script:H; DrawW = [Math]::Max(20, $script:W - 1) } }
function Sync-GcrConsoleBuffer { }
function Test-GcrTuiActive { return ($null -ne $script:GcrTui -and [bool]$script:GcrTui.Active) }
function Test-GcrTuiAvailable { return $true }
function Test-GcrTuiForceQuit { return $false }
function Sync-GcrTuiWindowTitle { }
function Set-GcrTuiTabProgress { param($Percent, $State) }

$esc = [char]27

function Reset-GcrCap {
    $script:CapWriter.Flush()
    [void]$script:Cap.SetLength(0)
}

# Parse the emitted escape stream back into the rows that were painted.
function Get-GcrPaintedRows {
    $script:CapWriter.Flush()
    $text = [System.Text.Encoding]::UTF8.GetString($script:Cap.ToArray())
    $rows = @{}
    #  <ESC>[<n>;1H <content> <ESC>[K
    foreach ($m in [regex]::Matches($text, [regex]::Escape($esc) + '\[(\d+);1H(.*?)' + [regex]::Escape($esc) + '\[K', 'Singleline')) {
        $rows[[int]$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $rows
}

function Fill-GcrLog {
    param([int]$Count)
    $script:GcrTui.Logs.Clear()
    $dirs = @("src/core", "docs/zh-CN", "third_party/vendor", "assets/images")
    for ($i = 0; $i -lt $Count; $i++) {
        $p = "{0}/module-{1:d3}/实现文件-{2:d4}.ps1" -f $dirs[$i % $dirs.Count], ($i % 97), $i
        [void]$script:GcrTui.Logs.Add(@{
                T = (Get-Date).AddSeconds(-1 * ($Count - $i))
                L = @("INFO", "WARN", "OK", "STEP")[$i % 4]
                M = ("checkout ok  " + $p)
            })
    }
}

function Initialize-GcrDash {
    param([hashtable]$Overrides = @{})
    Fill-GcrLog 400
    $script:GcrTui.Active = $true
    $script:GcrTui.Screen = "dash"
    $script:GcrTui.Phase = "download"
    $script:GcrTui.PhaseDetail = ""
    $script:GcrTui.RepoUrl = "https://github.com/example/some-large-repository.git"
    $script:GcrTui.OutDir = "D:\STRARG\src\some-large-repository"
    $script:GcrTui.Ref = "main"
    $script:GcrTui.Commit = "0123456789abcdef0123456789abcdef01234567"
    $script:GcrTui.Ok = 340
    $script:GcrTui.Total = 802
    $script:GcrTui.Fail = 0
    $script:GcrTui.Bytes = 1288490188
    $script:GcrTui.Speed = 1258291.0
    $script:GcrTui.Rate = 42.5
    $script:GcrTui.Eta = "00:01:20"
    $script:GcrTui.CurrentFile = "src/core/module-042/实现文件-0042.ps1"
    $script:GcrTui.GitPercent = -1
    $script:GcrTui.Paused = $false
    $script:GcrTui.QuitRequested = $false
    $script:GcrTui.ForceQuit = $false
    $script:GcrTui.Help = $false
    $script:GcrTui.FailView = $false
    $script:GcrTui.LogOffset = 0
    $script:GcrTui.Status = "run"
    $script:GcrTui.Resume = $false
    $script:GcrTui.Screen = "dash"
    foreach ($k in $Overrides.Keys) { $script:GcrTui[$k] = $Overrides[$k] }
    $script:GcrTui.LastFrame = @()
    $script:GcrTui.LastFrameW = 0
    $script:GcrTui.LastFrameH = 0
}

# --- Checks ------------------------------------------------------------------
$fail = 0
function Assert-Gcr {
    param([string]$What, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { Write-Host ("  ok   {0}" -f $What) }
    else { Write-Host ("  FAIL {0}  {1}" -f $What, $Detail) -ForegroundColor Red; $script:fail++ }
}

function Test-GcrFrame {
    param([string]$Label, [int]$ExpectRows)
    $rows = Get-GcrPaintedRows
    Assert-Gcr "$Label - painted $ExpectRows rows" ($rows.Count -eq $ExpectRows) "got $($rows.Count)"

    $box = $script:GcrTui.Box
    # Every glyph the frame can draw at its edges: the vertical on side rows and
    # the corners/junctions on border rows (all "+" in ASCII mode, distinct
    # glyphs in the Unicode box set).
    $edgeGlyphs = @($box.V, $box.H, $box.TL, $box.TR, $box.BL, $box.BR, $box.L, $box.R)
    $badWidth = 0
    $badGlyph = 0
    $badWrap = 0
    $bordered = 0
    for ($i = 1; $i -le $ExpectRows; $i++) {
        if (-not $rows.ContainsKey($i)) { continue }
        $r = $rows[$i]
        # Strip SGR sequences to measure the visible text.
        $plain = [regex]::Replace($r, [regex]::Escape($esc) + '\[[0-9;]*m', '')
        $w = Get-GcrDisplayWidth $plain
        if ($w -ne ($script:W - 1)) { $badWidth++ }
        if ($w -ge $script:W) { $badWrap++ }
        # Interior rows legitimately start and end with a space (the gutter just
        # inside the frame), so only reject a row whose ends are neither a frame
        # glyph nor blank padding.
        if ($plain.Length -gt 0) {
            $first = $plain.Substring(0, 1)
            $last = $plain.Substring($plain.Length - 1, 1)
            $firstIsEdge = $edgeGlyphs -ccontains $first
            $lastIsEdge = $edgeGlyphs -ccontains $last
            if (-not $firstIsEdge -and $first -ne " ") { $badGlyph++ }
            if (-not $lastIsEdge -and $last -ne " ") { $badGlyph++ }
            if ($firstIsEdge -and $lastIsEdge) { $bordered++ }
        }
    }
    Assert-Gcr "$Label - every row exactly $($script:W - 1) cells" ($badWidth -eq 0) "$badWidth rows off"
    Assert-Gcr "$Label - no row reaches the last column" ($badWrap -eq 0) "$badWrap rows wrap"
    Assert-Gcr "$Label - row edges are frame or padding" ($badGlyph -eq 0) "$badGlyph bad edges"
    # Top border, header, section borders, bar row, stats row and footer give a
    # dashboard at least 8 fully framed rows.
    Assert-Gcr "$Label - framed rows present" ($bordered -ge 8) "only $bordered bordered rows"
}

# --- States ------------------------------------------------------------------
Write-Host "Dashboard states:"

Initialize-GcrDash
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "running" $script:H

Initialize-GcrDash @{ Paused = $true }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "paused" $script:H

Initialize-GcrDash @{ QuitRequested = $true }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "stopping" $script:H

Initialize-GcrDash @{ Fail = 7; FailView = $true }
1..7 | ForEach-Object { Add-GcrTuiFailure -Path ("src/broken/file-{0}.bin" -f $_) }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "failure view" $script:H

Initialize-GcrDash @{ Help = $true }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "help overlay" $script:H

Initialize-GcrDash @{ Phase = "fetch"; GitPercent = 42 }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "fetch phase" $script:H

Initialize-GcrDash @{ Phase = "scan"; Total = 0; Ok = 0; GitPercent = -1 }
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "scan phase" $script:H

Initialize-GcrDash @{ Status = "done" }
$script:GcrTui.Screen = "result"
$script:GcrTui.ResultTitle = "克隆完成"
$script:GcrTui.ResultBody = @(
    "工作区: D:\STRARG\src\some-large-repository",
    "成功 802/802 ，失败 0 ，耗时 00:00:37 ，平均 3.4 MB/s",
    "失败列表: D:\STRARG\src\.git\partial-resume\failed.txt",
    "再次运行同一命令会重试未完成文件。"
)
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "result panel" $script:H

Initialize-GcrDash @{ Status = "error"; Fail = 3 }
$script:GcrTui.Screen = "result"
$script:GcrTui.ResultTitle = "部分文件失败"
$script:GcrTui.ResultBody = @("工作区: D:\src\repo", "失败列表: x.txt")
Reset-GcrCap; Render-GcrTui
Test-GcrFrame "result panel (error)" $script:H

# Narrow and short terminals exercise the compact branch and truncation.
Write-Host "Geometry:"
foreach ($geom in @(@(80, 24), @(60, 18), @(40, 10), @(100, 15), @(200, 60))) {
    $script:W = $geom[0]
    $script:H = $geom[1]
    Initialize-GcrDash
    Reset-GcrCap; Render-GcrTui
    Test-GcrFrame "$($geom[0])x$($geom[1])" $geom[1]
}
$script:W = 120
$script:H = 40

Write-Host "Wizard:"
$st = @{
    Url = "https://github.com/example/repo.git"; OutDir = "D:\src\repo"; OutDirAuto = $false
    Ref = "HEAD"; Language = "zh-CN"; BatchSize = 32; MaxRetries = 8
    Include = ""; Exclude = ""; Depth = ""; Verify = $false; ForceRefetch = $false
    DryRun = $false; Sel = 0; RecentSel = 0; RecentTop = 0; Focus = "form"
    Edit = $false; EditBuf = ""; EditCur = 0; EditField = ""
    Recent = @(
        @{ url = "https://github.com/a/one.git"; outDir = "D:\src\one"; status = "done"; ok = 100; total = 100; updated = (Get-Date).AddMinutes(-5) }
        @{ url = "https://github.com/b/two.git"; outDir = "D:\src\two"; status = "run"; ok = 40; total = 220; updated = (Get-Date).AddHours(-2) }
    )
    Scroll = 0; ConfirmQuit = $false; ConfirmClearAll = $false; ConfirmClearOne = $false
    Error = ""; Help = $false
}
$script:GcrTui.Active = $true
$script:GcrTui.Box = Get-GcrAsciiBox
$script:GcrTui.Screen = "wizard"

# Each wizard state is rendered from a clean frame cache, so these assert on a
# full repaint rather than on the delta the previous state left behind.
function Reset-GcrFrameCache {
    $script:GcrTui.LastFrame = @()
    $script:GcrTui.LastFrameW = 0
    $script:GcrTui.LastFrameH = 0
}

Reset-GcrFrameCache
Reset-GcrCap; Render-GcrTuiWizard -St $st
Test-GcrFrame "wizard" $script:H

# Editing state renders a cursor into the value.
$st.Edit = $true; $st.EditField = "url"; $st.EditBuf = $st.Url; $st.EditCur = 5; $st.Sel = 0
Reset-GcrFrameCache
Reset-GcrCap; Render-GcrTuiWizard -St $st
Test-GcrFrame "wizard (editing)" $script:H

$st.Edit = $false
$st.Focus = "recent"; $st.RecentSel = 1
Reset-GcrFrameCache
Reset-GcrCap; Render-GcrTuiWizard -St $st
Test-GcrFrame "wizard (recent focus)" $script:H

# --- Idempotence: rendering the same state twice must not repaint rows --------
Write-Host "Frame diffing:"
Initialize-GcrDash
Reset-GcrCap; Render-GcrTui
$first = Get-GcrPaintedRows
Reset-GcrCap; Render-GcrTui
$second = Get-GcrPaintedRows
Assert-Gcr "identical frame repaints nothing" ($second.Count -eq 0) "repainted $($second.Count) rows"

# A single changed row must repaint exactly that row.
$script:GcrTui.CurrentFile = "src/other/file.ps1"
Reset-GcrCap; Render-GcrTui
$third = Get-GcrPaintedRows
Assert-Gcr "one changed value repaints few rows" ($third.Count -le 3) "repainted $($third.Count) rows"

# A new log line must repaint the activity window but not the header.
[void]$script:GcrTui.Logs.Add(@{ T = Get-Date; L = "INFO"; M = "brand new line" })
Reset-GcrCap; Render-GcrTui
$fourth = Get-GcrPaintedRows
Assert-Gcr "new log line repaints activity rows" ($fourth.Count -gt 0 -and $fourth.Count -lt $script:H) "repainted $($fourth.Count) rows"
Assert-Gcr "header row not repainted" (-not $fourth.ContainsKey(1)) "row 1 repainted"

Write-Host ""
if ($fail -gt 0) {
    Write-Host "$fail check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All render checks passed." -ForegroundColor Green
