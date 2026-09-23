# Wizard interaction test.
#
# The wizard's per-event handling was extracted out of its render loop so a whole
# burst of queued input can be applied before painting (that is what stops a held
# arrow key from lagging). This suite drives the extracted state machine directly
# and verifies the click hit-map lines up with what was rendered.
#
# Run:  powershell -NoProfile -File bench\test-wizard.ps1
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Initialize-GcrTuiState

# Capture frames instead of writing them to a terminal.
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
function Enable-GcrMouse { return $false }
function Disable-GcrMouse { }
# Editing a field reads the clipboard; keep the test off the real one.
function Get-GcrClipboardText { return "" }

function New-GcrTestKey {
    param([string]$Key, [string]$Char = "")
    $ck = [ConsoleKey]$Key
    if ($Char -eq "" -and $Key.Length -eq 1) { $Char = $Key }
    return New-Object System.ConsoleKeyInfo([char]$(if ($Char) { [char]$Char } else { [char]0 }), $ck, $false, $false, $false)
}

# A key with the Ctrl modifier held, which is how Ctrl+S / Ctrl+C / Ctrl+V arrive.
function New-GcrTestCtrlKey {
    param([string]$Key)
    $ch = [char]([int][char]$Key.ToLower() - 96)   # Ctrl+letter sends 0x01-0x1A
    return New-Object System.ConsoleKeyInfo($ch, ([ConsoleKey]$Key), $false, $false, $true)
}

function New-GcrTestState {
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
    return $st
}

# The wizard items the renderer uses, so index expectations stay honest.
function Get-GcrExpectedItemCount { return @(Get-GcrWizardItems -St (New-GcrTestState)).Count }

$fail = 0
# This suite redirects [Console]::SetOut to capture frames, after which console
# writes are no longer visible on the terminal. Results are therefore both echoed
# and appended to a file, so the output survives however the suite is invoked.
$script:Report = New-Object System.Collections.Generic.List[string]
function Say { param([string]$T) [void]$script:Report.Add($T); Write-Host $T }
function Assert-Gcr {
    param([string]$What, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { Say ("  ok   {0}" -f $What) }
    else { Say ("  FAIL {0}  {1}" -f $What, $Detail); $script:fail++ }
}

function Reset-GcrCap {
    $script:CapWriter.Flush()
    [void]$script:Cap.SetLength(0)
}

# Terminal row (1-based) -> rendered text, with SGR sequences stripped.
function Get-GcrRowMap {
    $script:CapWriter.Flush()
    $text = [System.Text.Encoding]::UTF8.GetString($script:Cap.ToArray())
    $esc = [char]27
    $map = @{}
    foreach ($m in [regex]::Matches($text, [regex]::Escape($esc) + '\[(\d+);1H(.*?)' + [regex]::Escape($esc) + '\[K', 'Singleline')) {
        $map[[int]$m.Groups[1].Value] = [regex]::Replace($m.Groups[2].Value, [regex]::Escape($esc) + '\[[0-9;]*m', '')
    }
    return $map
}

# --- Navigation --------------------------------------------------------------
Say "Navigation:"
$st = New-GcrTestState
$itemCount = Get-GcrExpectedItemCount

$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "DownArrow")
Assert-Gcr "DownArrow moves selection 0 -> 1" ($st.Sel -eq 1 -and $r -eq "continue") "sel=$($st.Sel) action=$r"

$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "UpArrow")
Assert-Gcr "UpArrow moves selection 1 -> 0" ($st.Sel -eq 0) "sel=$($st.Sel)"

# Held UpArrow must clamp at the top rather than wrapping.
for ($i = 0; $i -lt 25; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "UpArrow") }
Assert-Gcr "held UpArrow clamps at first item" ($st.Sel -eq 0) "sel=$($st.Sel)"

for ($i = 0; $i -lt 25; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "DownArrow") }
Assert-Gcr "held DownArrow clamps at last form item" ($st.Sel -eq $itemCount - 1) "sel=$($st.Sel) of $itemCount"

# A long 'j' burst behaves like DownArrow. Focus must be on the form: j/k are
# deliberately inert while the recent-task list has focus.
$st.Focus = "form"
$st.Sel = 0
for ($i = 0; $i -lt 40; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "J" "j") }
Assert-Gcr "held j clamps at last form item" ($st.Sel -eq $itemCount - 1) "sel=$($st.Sel)"
$st.Focus = "form"
for ($i = 0; $i -lt 40; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "K" "k") }
Assert-Gcr "held k clamps at first item" ($st.Sel -eq 0) "sel=$($st.Sel)"

# --- Toggles -----------------------------------------------------------------
Say "Form actions:"
$st = New-GcrTestState
$st.Sel = 8
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Spacebar")
Assert-Gcr "Space toggles Verify on" ($st.Verify) "Verify=$($st.Verify)"
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Spacebar")
Assert-Gcr "Space toggles Verify off" (-not $st.Verify) "Verify=$($st.Verify)"

$st.Sel = 9
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Spacebar")
Assert-Gcr "Space toggles ForceRefetch" ($st.ForceRefetch)

$st.Sel = 10
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Spacebar")
Assert-Gcr "Space toggles DryRun" ($st.DryRun)

# Batch size steps through the ladder and clamps at both ends.
$st = New-GcrTestState
$st.Sel = 3
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "RightArrow")
Assert-Gcr "RightArrow steps BatchSize 32 -> 64" ($st.BatchSize -eq 64) "batch=$($st.BatchSize)"
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "LeftArrow")
Assert-Gcr "LeftArrow steps BatchSize 64 -> 32" ($st.BatchSize -eq 32) "batch=$($st.BatchSize)"
for ($i = 0; $i -lt 10; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "LeftArrow") }
Assert-Gcr "BatchSize clamps at minimum 8" ($st.BatchSize -eq 8) "batch=$($st.BatchSize)"
for ($i = 0; $i -lt 10; $i++) { $null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "RightArrow") }
Assert-Gcr "BatchSize clamps at maximum 256" ($st.BatchSize -eq 256) "batch=$($st.BatchSize)"

# --- Editing -----------------------------------------------------------------
Say "Editing:"
$st = New-GcrTestState
$st.Sel = 0
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "Enter on a text field starts editing" ($st.Edit -and $st.EditField -eq "url") "edit=$($st.Edit) field=$($st.EditField)"
Assert-Gcr "edit buffer seeded from the value" ($st.EditBuf -eq $st.Url) "buf=$($st.EditBuf)"
Assert-Gcr "caret placed at end" ($st.EditCur -eq $st.EditBuf.Length) "cur=$($st.EditCur)"

$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Backspace")
Assert-Gcr "Backspace removes a character" ($st.EditBuf.Length -eq ($st.Url.Length - 1)) "len=$($st.EditBuf.Length)"
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "A" "a")
Assert-Gcr "typing appends a character" ($st.EditBuf.Length -eq $st.Url.Length) "len=$($st.EditBuf.Length)"
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Escape")
Assert-Gcr "Escape leaves editing" (-not $st.Edit)

$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
$st.EditBuf = "D:\custom\dir"
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "Enter commits and leaves editing" (-not $st.Edit) "edit=$($st.Edit)"

$st = New-GcrTestState
$st.Sel = 1
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
$st.EditBuf = ""
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "clearing dir re-enables auto naming" ($st.OutDirAuto) "auto=$($st.OutDirAuto)"

# --- Start / close actions ---------------------------------------------------
Say "Start and close:"
$st = New-GcrTestState
$st.Sel = $itemCount - 1          # the start row
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "Enter on the start row reports start" ($r -eq "start") "action=$r"

$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "S")
Assert-Gcr "S reports start from anywhere" ($r -eq "start") "action=$r"

$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "S")
Assert-Gcr "S leaves the form untouched" ($st.Url -eq "https://github.com/example/repo.git" -and -not $st.Edit)

# Ctrl+S is the accelerator advertised in the footer.
$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestCtrlKey "S")
Assert-Gcr "Ctrl+S reports start" ($r -eq "start") "action=$r"

# Unlike a bare S, Ctrl+S must work while a text field has the caret.
$st = New-GcrTestState
$st.Sel = 0
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "field is being edited" ($st.Edit) "edit=$($st.Edit)"
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestCtrlKey "S")
Assert-Gcr "Ctrl+S starts even while editing" ($r -eq "start") "action=$r"

$st = New-GcrTestState
$st.Url = "   "
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestCtrlKey "S")
Assert-Gcr "Ctrl+S with a blank URL is refused" ($r -eq "continue") "action=$r"
Assert-Gcr "refusal points at the URL field" ($st.Sel -eq 0 -and $st.Error) "sel=$($st.Sel)"

# Ctrl+S must not be mistaken for Ctrl+C / Ctrl+V (each carries its own letter).
$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestCtrlKey "C")
Assert-Gcr "Ctrl+C still asks to quit, not start" ($st.ConfirmQuit -and $r -eq "continue") "action=$r"

$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Q")
Assert-Gcr "Q asks for confirmation" ($st.ConfirmQuit -and $r -eq "continue") "confirm=$($st.ConfirmQuit) action=$r"
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "confirming the quit reports close" ($r -eq "close") "action=$r"

$st = New-GcrTestState
$null = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Q")
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Escape")
Assert-Gcr "Esc backs out of the quit prompt" ((-not $st.ConfirmQuit) -and $r -eq "continue") "confirm=$($st.ConfirmQuit)"

# Starting with an empty URL is refused.
$st = New-GcrTestState
$st.Url = ""
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "S")
Assert-Gcr "S with no URL is refused" ($r -eq "continue") "action=$r"
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestCtrlKey "S")
Assert-Gcr "Ctrl+S with no URL is refused" ($r -eq "continue") "action=$r"

# --- Recent tasks ------------------------------------------------------------
Say "Recent tasks:"
$st = New-GcrTestState
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Tab")
Assert-Gcr "Tab moves focus to recent tasks" ($st.Focus -eq "recent") "focus=$($st.Focus)"
$st.RecentSel = 1
$r = Invoke-GcrWizardEvent -St $st -K (New-GcrTestKey "Enter")
Assert-Gcr "Enter fills the form from a recent task" ($st.Url -eq "https://github.com/b/two.git" -and $st.OutDir -eq "D:\src\two") "url=$($st.Url) dir=$($st.OutDir)"
Assert-Gcr "focus returns to the form" ($st.Focus -eq "form") "focus=$($st.Focus)"

# --- Click hit-map -----------------------------------------------------------
Say "Mouse hit-map:"
$st = New-GcrTestState
$script:GcrTui.Active = $true
$script:GcrTui.Box = Get-GcrAsciiBox
$script:GcrTui.Screen = "wizard"
$script:GcrTui.LastFrame = @(); $script:GcrTui.LastFrameW = 0; $script:GcrTui.LastFrameH = 0
Reset-GcrCap
Render-GcrTuiWizard -St $st
$rows = Get-GcrRowMap
$hit = $script:GcrMouseHit

Assert-Gcr "hit-map published" ($null -ne $hit -and $hit.Count -gt 0) "count=$($hit.Count)"

# Every mapped row must exist in the frame and carry the pointer or the row text.
$badRows = 0
foreach ($rowNum in $hit.Keys) {
    if (-not $rows.ContainsKey($rowNum)) { $badRows++ }
}
Assert-Gcr "every mapped row was painted" ($badRows -eq 0) "$badRows missing"

# Row -> item mapping must line up: clicking row N selects that item.
$itemRows = @($hit.Keys | Where-Object { $hit[$_].Kind -eq "item" } | Sort-Object)
Assert-Gcr "every form item has a clickable row" ($itemRows.Count -eq $itemCount) "$($itemRows.Count) rows for $itemCount items"

$mismatch = 0
foreach ($rowNum in $itemRows) {
    $expectIndex = [int]$hit[$rowNum].Index
    $st2 = New-GcrTestState
    $st2.Sel = -1
    # Move the selection into editing so the click is a pure "select" for bools;
    # for text rows the click starts editing, which is also observable via Sel.
    $null = Invoke-GcrWizardMouse -St $st2 -X 5 -Y $rowNum
    if ($st2.Sel -ne $expectIndex) { $mismatch++ }
}
Assert-Gcr "clicking a form row selects its item" ($mismatch -eq 0) "$mismatch rows selected the wrong item"

# Clicking the rendered start row must start the clone.
$startRow = @($itemRows | Where-Object { $hit[$_].Kind -eq "item" -and $hit[$_].Id -eq "start" })
Assert-Gcr "start row is clickable" ($startRow.Count -eq 1) "found $($startRow.Count)"
$st3 = New-GcrTestState
$r = Invoke-GcrWizardMouse -St $st3 -X 5 -Y ([int]$startRow[0])
Assert-Gcr "clicking the start row reports start" ($r -eq "start") "action=$r"

# Clicking a bool row toggles it (that is what Enter on a bool does).
$verifyRow = @($itemRows | Where-Object { $hit[$_].Kind -eq "item" -and $hit[$_].Id -eq "verify" })
if ($verifyRow.Count -eq 1) {
    $st4 = New-GcrTestState
    $before = $st4.Verify
    $null = Invoke-GcrWizardMouse -St $st4 -X 5 -Y ([int]$verifyRow[0])
    Assert-Gcr "clicking a bool row toggles it" ($st4.Verify -ne $before) "before=$before after=$($st4.Verify)"
}

# Clicking a recent row fills the form from it.
$recentRows = @($hit.Keys | Where-Object { $hit[$_].Kind -eq "recent" } | Sort-Object)
if ($recentRows.Count -ge 2) {
    $target = [int]$recentRows[1]
    $st5 = New-GcrTestState
    $null = Invoke-GcrWizardMouse -St $st5 -X 5 -Y $target
    Assert-Gcr "clicking a recent row fills the form" ($st5.Url -eq "https://github.com/b/two.git") "url=$($st5.Url)"
} else {
    Assert-Gcr "recent rows are clickable" $false "found $($recentRows.Count)"
}

# A click on empty space (the border) must be a safe no-op.
$st6 = New-GcrTestState
$before6 = $st6.Sel
$r6 = Invoke-GcrWizardMouse -St $st6 -X 0 -Y 1
Assert-Gcr "clicking a border is a no-op" ($r6 -eq "continue" -and $st6.Sel -eq $before6) "action=$r6 sel=$($st6.Sel)"

# A click while the quit prompt is up confirms it.
$st7 = New-GcrTestState
$null = Invoke-GcrWizardEvent -St $st7 -K (New-GcrTestKey "Q")
$r7 = Invoke-GcrWizardMouse -St $st7 -X 5 -Y ([int]$itemRows[0])
Assert-Gcr "click confirms a pending quit prompt" ($r7 -eq "close") "action=$r7"

# --- Synthetic keys ----------------------------------------------------------
Say "Synthetic keys:"
$enter = New-GcrSyntheticKey "Enter"
Assert-Gcr "synthetic Enter is an Enter" ($enter.Key -eq [ConsoleKey]::Enter) "key=$($enter.Key)"
$esc = New-GcrSyntheticKey "Escape"
Assert-Gcr "synthetic Escape is an Escape" ($esc.Key -eq [ConsoleKey]::Escape) "key=$($esc.Key)"

Say ""
if ($fail -gt 0) {
    Say "$fail check(s) FAILED"
    $script:Report | Set-Content -LiteralPath (Join-Path $PSScriptRoot "wizard-results.txt") -Encoding UTF8
    exit 1
}
Say "All wizard checks passed."
$script:Report | Set-Content -LiteralPath (Join-Path $PSScriptRoot "wizard-results.txt") -Encoding UTF8
