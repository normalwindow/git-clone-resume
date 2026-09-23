#Requires -Version 5.1
# Terminal UI for git-clone-resume. Dot-sourced by git-clone-resume.ps1.
# PowerShell 5.1 compatible. Interactive host -> full-screen dashboard;
# redirected/CI -> caller keeps the original CLI.

Set-StrictMode -Version Latest

$script:GcrTui = $null
$script:GcrEsc = [char]27
$script:GcrReset = "$([char]27)[0m"
$script:GcrCurrentProc = $null
$script:GcrOrigOutMode = $null
$script:GcrOrigInMode = $null
$script:GcrOrigTitle = $null
$script:GcrOrigCursor = $true
$script:GcrOrigTreatCtrlC = $false
$script:GcrNativeReady = $false
$script:GcrMouseReady = $false
$script:GcrMouseWanted = $null
# Consecutive mouse reads that saw a keyboard record; at 2 mouse support is retired.
$script:GcrMouseFaults = 0
# Console events decoded from ReadConsoleInput, waiting to be consumed. A List
# rather than a Queue so it can be batch-drained without allocating per item.
$script:GcrPendingInput = New-Object System.Collections.Generic.List[object]
# Row -> action map for clickable regions, republished by each wizard render.
$script:GcrMouseHit = $null

function Get-GcrCharWidth {
    param([char]$Ch)
    $code = [int]$Ch
    if ($code -le 31 -or $code -eq 127) { return 0 }
    if ($code -lt 127) { return 1 }
    if ($code -ge 0x1100 -and (
            $code -le 0x115F -or
            $code -eq 0x2329 -or $code -eq 0x232A -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE19) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)
        )) { return 2 }
    return 1
}

# ---------------------------------------------------------------------------
# Character width table
# ---------------------------------------------------------------------------
# Measuring text cell-by-cell through a PowerShell function is the most
# expensive thing this TUI does. A PowerShell function call costs a few
# microseconds, so a 70-character log line used to cost ~1.2 ms to measure, and
# a 40-row frame spent ~67 ms of its ~81 ms budget inside Get-GcrCharWidth alone
# (~12 fps, which is what made the interface feel sluggish). The table below is
# exactly the same classification, precomputed once for every BMP code point, so
# measuring becomes a flat array lookup inside a for loop with no calls.
#
# 64K bytes of byte[]; built once and shared for the process lifetime. Use
# Get-GcrWidthTable rather than calling this when you want the array back:
# `return $array` makes PowerShell enumerate it, which cost ~20 ms per call on a
# 64K byte[] even when the table was already built.
$script:GcrWidthTable = $null

function Get-GcrWidthTable {
    if ($null -ne $script:GcrWidthTable) { return , $script:GcrWidthTable }
    $t = New-Object byte[] 65536
    for ($code = 0; $code -lt 65536; $code++) {
        if ($code -le 31 -or $code -eq 127) { $t[$code] = 0 }
        elseif ($code -lt 127) { $t[$code] = 1 }
        elseif ($code -ge 0x1100 -and (
                $code -le 0x115F -or
                $code -eq 0x2329 -or
                $code -eq 0x232A -or
                ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
                ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
                ($code -ge 0xF900 -and $code -le 0xFAFF) -or
                ($code -ge 0xFE10 -and $code -le 0xFE19) -or
                ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
                ($code -ge 0xFF00 -and $code -le 0xFF60) -or
                ($code -ge 0xFFE0 -and $code -le 0xFFE6)
            )) { $t[$code] = 2 }
        else { $t[$code] = 1 }
    }
    $script:GcrWidthTable = $t
    return , $t
}

# Kept as an alias so existing callers keep working.
function Initialize-GcrWidthTable {
    return , (Get-GcrWidthTable)
}

# CSI escape sequences, stripped before measuring styled text.
$script:GcrAnsiRegex = [char]27 + '\[[0-9;?]*[ -/]*[@-~]'

# The width table is built once by Initialize-GcrTui before the first frame, so
# the hot helpers below index it directly instead of paying for a guard and a
# function call on every invocation.
function Get-GcrDisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $plain = [regex]::Replace($Text, $script:GcrAnsiRegex, "")
    if ($plain.Length -eq 0) { return 0 }
    $rt = $script:GcrWidthTable
    if ($null -eq $rt) { $rt = Get-GcrWidthTable }
    $w = 0
    for ($i = 0; $i -lt $plain.Length; $i++) { $w += $rt[$plain[$i]] }
    return $w
}

# Width of a string already known to contain no escape sequences. The renderer
# formats plain text it built itself, so it can skip the regex strip.
function Get-GcrPlainWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $rt = $script:GcrWidthTable
    if ($null -eq $rt) { $rt = Get-GcrWidthTable }
    $w = 0
    for ($i = 0; $i -lt $Text.Length; $i++) { $w += $rt[$Text[$i]] }
    return $w
}

function Truncate-GcrDisplay {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return "" }
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $rt = $script:GcrWidthTable
    if ($null -eq $rt) { $rt = Get-GcrWidthTable }
    $w = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $w += $rt[$Text[$i]]
        if ($w -gt $Width) { break }
    }
    if ($w -le $Width) { return $Text }
    $ellipsis = "..."
    $budget = $Width - 3
    if ($budget -lt 1) { return Truncate-GcrDisplay -Text "." -Width $Width }
    # Re-cut against the tighter ellipsis budget.
    $w = 0
    $take = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $cw = $rt[$Text[$i]]
        if ($w + $cw -gt $budget) { break }
        $w += $cw
        $take = $i + 1
    }
    return $Text.Substring(0, $take) + $ellipsis
}

function Format-GcrCell {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return "" }
    $rt = $script:GcrWidthTable
    if ($null -eq $rt) { $rt = Get-GcrWidthTable }
    $t = [string]$Text
    # Callers may pass styled text (the width helpers strip escape sequences
    # before measuring). The IndexOf guard means plain text - the overwhelmingly
    # common case in the render loop - skips the regex entirely.
    if ($t.IndexOf($script:GcrEsc) -ge 0) { $t = [regex]::Replace($t, $script:GcrAnsiRegex, "") }
    # Measure and pad/cut in one scan. The old version measured the text, called
    # Truncate-GcrDisplay (which measured again) and then measured the result a
    # third time, tripling the most expensive operation in the renderer.
    $w = 0
    for ($i = 0; $i -lt $t.Length; $i++) {
        $w += $rt[$t[$i]]
        if ($w -gt $Width) { break }
    }
    if ($w -gt $Width) {
        $t = Truncate-GcrDisplay -Text $t -Width $Width
        $w = Get-GcrPlainWidth $t
    }
    if ($w -lt $Width) { $t = $t + (" " * ($Width - $w)) }
    return $t
}

function Get-GcrColor {
    param([string]$Name)
    $e = $script:GcrEsc
    switch ($Name) {
        "reset"  { return "$e[0m" }
        "bold"   { return "$e[1m" }
        "dim"    { return "$e[2m" }
        "rev"    { return "$e[7m" }
        "cyan"   { return "$e[96m" }
        "blue"   { return "$e[94m" }
        "green"  { return "$e[92m" }
        "yellow" { return "$e[93m" }
        "red"    { return "$e[91m" }
        "white"  { return "$e[97m" }
        "gray"   { return "$e[90m" }
        "teal"   { return "$e[38;2;94;234;212m" }
        default  { return "$e[0m" }
    }
}

function Get-GcrLevelColor {
    param([string]$Level)
    switch ($Level) {
        "OK"    { return Get-GcrColor "green" }
        "STEP"  { return Get-GcrColor "cyan" }
        "WARN"  { return Get-GcrColor "yellow" }
        "ERROR" { return Get-GcrColor "red" }
        default { return Get-GcrColor "dim" }
    }
}

# Classify a result-panel line so the dashboard can colour it by meaning:
# paths in cyan, success in green, failures in yellow/red, hints dim.
function Get-GcrResultLineKind {
    param([string]$Text)
    $t = [string]$Text
    if ([string]::IsNullOrWhiteSpace($t)) { return "info" }
    if ($t -match "^(工作区|Workspace|仓库目录|Repository directory|清单文件|List file)") { return "path" }
    # A summary line that reports failures must not look like a success line.
    if ($t -match "(失败|failed)\s+[1-9][0-9]*") { return "warn" }
    if ($t -match "成功|Succeeded|全部文件已就绪|All files are ready|克隆完成|Clone complete|文件: |Files: |DryRun 完成|DryRun complete") { return "ok" }
    if ($t -match "失败列表|Failure list|部分文件失败|Some files failed|仍失败|Still failed|FAILED|failed [1-9]") { return "warn" }
    if ($t -match "再次运行|Run the same command|重试|retry") { return "dim" }
    if ($t -match "失败|failed|错误|Error|出错") { return "err" }
    return "info"
}

function Test-GcrTuiAvailable {
    if ($Host.Name -match "ISE") { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    try {
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -lt 40 -or $h -lt 10) { return $false }
    } catch { return $false }
    try {
        $null = [Console]::KeyAvailable
    } catch { return $false }
    return $true
}

function Test-GcrTuiActive {
    return ($null -ne $script:GcrTui -and [bool]$script:GcrTui.Active)
}

function Test-GcrTuiQuit {
    return (Test-GcrTuiActive) -and [bool]$script:GcrTui.QuitRequested
}

function Test-GcrTuiForceQuit {
    return (Test-GcrTuiActive) -and [bool]$script:GcrTui.ForceQuit
}

function Get-GcrNativeType {
    if (-not ("GitCloneResume.Native" -as [type])) {
        Add-Type -Namespace GitCloneResume -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);

// ReadConsoleInput is the only Windows API that reports mouse events; the
// managed [Console]::ReadKey path sees keyboard input exclusively. The layouts
// below are the documented Win32 ones (KEY_EVENT_RECORD and MOUSE_EVENT_RECORD
// are both 16 bytes, INPUT_RECORD is 20 on 64-bit).
[StructLayout(LayoutKind.Sequential)]
public struct KEY_EVENT_RECORD {
    [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public char UnicodeChar;
    public uint dwControlKeyState;
}

[StructLayout(LayoutKind.Sequential)]
public struct MOUSE_EVENT_RECORD {
    public short dwMousePositionX;
    public short dwMousePositionY;
    public uint dwButtonState;
    public uint dwControlKeyState;
    public uint dwEventFlags;
}

[StructLayout(LayoutKind.Explicit)]
public struct INPUT_RECORD_UNION {
    [FieldOffset(0)] public KEY_EVENT_RECORD KeyEvent;
    [FieldOffset(0)] public MOUSE_EVENT_RECORD MouseEvent;
}

[StructLayout(LayoutKind.Sequential)]
public struct INPUT_RECORD {
    public ushort EventType;
    public INPUT_RECORD_UNION Event;
}

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="ReadConsoleInputW")]
public static extern bool ReadConsoleInput(System.IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool PeekConsoleInput(System.IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);
"@
    }
    return [GitCloneResume.Native]
}

# Event types in an INPUT_RECORD.
$script:GcrInputKeyEvent = 0x0001
$script:GcrInputMouseEvent = 0x0002

# dwControlKeyState bits.
$script:GcrShiftPressed = 0x0010
$script:GcrCtrlPressed = 0x0008

# dwEventFlags values. 0 means a real press/release; 1 is a movement report.
$script:GcrMouseMoved = 0x0001
$script:GcrMouseDoubleClick = 0x0002
$script:GcrMouseWheeled = 0x0004

# dwButtonState bits.
$script:GcrFromLeft1stButton = 0x0001

function Enable-GcrVt {
    try {
        $native = Get-GcrNativeType
        $hOut = $native::GetStdHandle(-11)
        $hIn = $native::GetStdHandle(-10)
        $outMode = [uint32]0
        $inMode = [uint32]0
        if ($native::GetConsoleMode($hOut, [ref]$outMode)) {
            $script:GcrOrigOutMode = $outMode
            $vt = [uint32]0x0004
            $processed = [uint32]0x0001
            $wrap = [uint32]0x0002
            $disableNl = [uint32]0x0008
            $newOut = ([uint32]($outMode -bor $processed -bor $vt -bor $disableNl)) -band (-bnot $wrap)
            [void]$native::SetConsoleMode($hOut, $newOut)
        }
        if ($native::GetConsoleMode($hIn, [ref]$inMode)) {
            $script:GcrOrigInMode = $inMode
            $extended = [uint32]0x0080
            $quickEdit = [uint32]0x0040
            $newIn = ($inMode -bor $extended) -band (-bnot $quickEdit)
            [void]$native::SetConsoleMode($hIn, $newIn)
        }
        $script:GcrNativeReady = $true
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Mouse input
# ---------------------------------------------------------------------------
# Mouse reporting is opt-out via GCR_MOUSE=0 and only enabled while a screen that
# uses clicks is on show. Enabling ENABLE_MOUSE_INPUT makes the console deliver
# mouse events to the application, which also means the terminal's own
# click-drag text selection stops working for the duration - that is why the
# wizard turns it off again as soon as a clone starts (see Show-GcrTuiWizard's
# exit paths), and why GCR_MOUSE=0 exists.
function Test-GcrMouseWanted {
    if ($env:GCR_MOUSE -eq "0") { return $false }
    return $true
}

function Enable-GcrMouse {
    if (-not $script:GcrNativeReady) { return $false }
    if ($script:GcrMouseReady) { return $true }
    if (-not (Test-GcrMouseWanted)) { return $false }
    try {
        $native = Get-GcrNativeType
        $hIn = $native::GetStdHandle(-10)
        if ($hIn -eq [IntPtr]::Zero -or $hIn -eq [IntPtr](-1)) { return $false }
        $mode = [uint32]0
        if (-not $native::GetConsoleMode($hIn, [ref]$mode)) { return $false }

        $mouseInput = [uint32]0x0010
        $quickEdit = [uint32]0x0040
        # ENABLE_MOUSE_INPUT is the only change needed: it already turns off
        # QuickEdit, and it must be paired with ENABLE_EXTENDED_FLAGS for the
        # console to honour the write. Nothing else about the keyboard mode is
        # touched, so key input behaves exactly as it did before.
        $extended = [uint32]0x0080
        $newMode = ($mode -bor $mouseInput -bor $extended) -band (-bnot $quickEdit)
        if (-not $native::SetConsoleMode($hIn, $newMode)) { return $false }

        # Allocate the record buffer now, so the reader never has to.
        if ($null -eq $script:GcrInputBuf) {
            $script:GcrInputBuf = New-Object 'GitCloneResume.Native+INPUT_RECORD[]' 64
        }
        $script:GcrMouseReady = $true
        $script:GcrMouseFaults = 0
        return $true
    } catch {
        $script:GcrMouseReady = $false
        return $false
    }
}

function Disable-GcrMouse {
    if (-not $script:GcrMouseReady) { return }
    $script:GcrMouseReady = $false
    try {
        $native = Get-GcrNativeType
        $hIn = $native::GetStdHandle(-10)
        $mode = [uint32]0
        if (-not $native::GetConsoleMode($hIn, [ref]$mode)) { return }
        $mouseInput = [uint32]0x0010
        [void]$native::SetConsoleMode($hIn, [uint32]($mode -band (-bnot $mouseInput)))
    } catch { }
}

function Restore-GcrVt {
    if (-not $script:GcrNativeReady) { return }
    try {
        $native = Get-GcrNativeType
        if ($null -ne $script:GcrOrigOutMode) {
            [void]$native::SetConsoleMode($native::GetStdHandle(-11), [uint32]$script:GcrOrigOutMode)
        }
        if ($null -ne $script:GcrOrigInMode) {
            [void]$native::SetConsoleMode($native::GetStdHandle(-10), [uint32]$script:GcrOrigInMode)
        }
    } catch { }
}

function Sync-GcrConsoleBuffer {
    try {
        $w = [int][Console]::WindowWidth
        $h = [int][Console]::WindowHeight
        if ($w -lt 1 -or $h -lt 1) { return }
        if ([Console]::BufferWidth -ne $w -or [Console]::BufferHeight -ne $h) {
            [Console]::SetBufferSize($w, $h)
        }
    } catch { }
}

function Get-GcrTuiSize {
    Sync-GcrConsoleBuffer
    $w = 80
    $h = 24
    try {
        $w = [int][Console]::WindowWidth
        $h = [int][Console]::WindowHeight
    } catch {
        try {
            $w = [int]$Host.UI.RawUI.WindowSize.Width
            $h = [int]$Host.UI.RawUI.WindowSize.Height
        } catch { }
    }
    if ($w -lt 40) { $w = 40 }
    if ($h -lt 10) { $h = 10 }
    # Never paint the last column: a full-width write wraps and scrolls the buffer.
    $size = @{ W = $w; H = $h; DrawW = [Math]::Max(20, $w - 1) }
    return $size
}

function Get-GcrAsciiBox {
    return @{
        H = "-"
        V = "|"
        TL = "+"
        TR = "+"
        BL = "+"
        BR = "+"
        L = "+"
        R = "+"
        BarF = "#"
        BarE = "-"
        Pointer = ">"
        Dot = "."
    }
}

function Get-GcrUnicodeBox {
    return @{
        H = [string][char]0x2500
        V = [string][char]0x2502
        TL = [string][char]0x256D
        TR = [string][char]0x256E
        BL = [string][char]0x2570
        BR = [string][char]0x256F
        L = [string][char]0x251C
        R = [string][char]0x2524
        BarF = [string][char]0x2588
        BarE = [string][char]0x2591
        Pointer = ">"
        Dot = [string][char]0x00B7
    }
}

function Measure-GcrCellAdvance {
    param([char]$Ch)
    try {
        $left = [Console]::CursorLeft
        $top = [Console]::CursorTop
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write([string]$Ch)
        $adv = [int][Console]::CursorLeft
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write(" ")
        [Console]::SetCursorPosition($left, $top)
        if ($adv -lt 1) { return 1 }
        return $adv
    } catch {
        return 1
    }
}

function Resolve-GcrBox {
    if ($env:GCR_ASCII -eq "1") { return Get-GcrAsciiBox }
    if ($env:GCR_UNICODE -eq "1") { return Get-GcrUnicodeBox }
    $probe = @(
        [char]0x2500
        [char]0x256D
        [char]0x2588
        [char]0x2591
    )
    foreach ($ch in $probe) {
        if ((Measure-GcrCellAdvance $ch) -ge 2) { return Get-GcrAsciiBox }
    }
    return Get-GcrUnicodeBox
}

function Initialize-GcrTuiState {
    $box = Get-GcrAsciiBox
    $script:GcrTui = @{
        Active        = $false
        UseUnicode    = $false
        Box           = $box
        Width         = 80
        Height        = 24
        LastFrame     = @()
        LastFrameW    = 0
        LastFrameH    = 0
        Logs          = New-Object System.Collections.ArrayList
        LogOffset     = 0
        Phase         = "idle"
        PhaseDetail   = ""
        RepoUrl       = ""
        OutDir        = ""
        Ref           = "HEAD"
        Commit        = ""
        Resume        = $false
        Ok            = 0
        Total         = 0
        Fail          = 0
        Bytes         = [int64]0
        Rate          = 0.0
        Speed         = 0.0
        Eta           = "--:--:--"
        CurrentFile   = ""
        GitPercent    = -1
        Paused        = $false
        QuitRequested = $false
        ForceQuit     = $false
        Dirty         = $true
        LastDraw      = [datetime]::MinValue
        Help          = $false
        FailView      = $false
        Failures      = New-Object System.Collections.ArrayList
        StartedAt     = $null
        Status        = "run"
        ResultTitle   = ""
        ResultBody    = @()
        Tick          = 0
        Screen        = "dash"
        ErrorFlash    = ""
        Sha1Noise     = 0
        # Raised by S on the dashboard: open the setup wizard again while the
        # dashboard is idle (waiting for a keypress between batches), so a clone
        # can be started without relaunching the script.
        WizardRequested = $false
    }
}

function Initialize-GcrTui {
    if (Test-GcrTuiActive) { return $true }
    if (-not (Test-GcrTuiAvailable)) { return $false }
    Initialize-GcrTuiState
    # Build the character-width table once here (~50 ms) rather than letting the
    # first frame pay for it, so the UI never freezes on its first paint.
    [void](Get-GcrWidthTable)
    try { $script:GcrOrigTitle = [Console]::Title } catch { }
    try { $script:GcrOrigCursor = [Console]::CursorVisible } catch { }
    try { $script:GcrOrigTreatCtrlC = [Console]::TreatControlCAsInput } catch { }
    [void](Enable-GcrVt)
    try { [Console]::TreatControlCAsInput = $true } catch { }
    try { [Console]::CursorVisible = $false } catch { }
    $e = $script:GcrEsc
    try {
        [Console]::Write("{0}[?1049h{0}[?25l{0}[2J{0}[H" -f $e)
    } catch { }
    Sync-GcrConsoleBuffer
    $box = Resolve-GcrBox
    $script:GcrTui.Box = $box
    $script:GcrTui.UseUnicode = ($box.H -ne "-")
    # Title is owned by git-clone-resume.ps1 (Set-GcrWindowTitle) so it can be
    # restored on every exit path; fall back to a direct set if unavailable.
    if (Get-Command Set-GcrWindowTitle -ErrorAction SilentlyContinue) {
        Set-GcrWindowTitle -Text "git-clone-resume"
    } else {
        try { [Console]::Title = "git-clone-resume" } catch { }
    }
    $script:GcrTui.Active = $true
    $script:GcrTui.Dirty = $true
    $script:GcrTui.LastFrame = @()
    return $true
}

function Close-GcrTui {
    if ($null -eq $script:GcrTui -or -not $script:GcrTui.Active) {
        $script:GcrTui = $null
        if (Get-Command Restore-GcrWindowTitle -ErrorAction SilentlyContinue) { Restore-GcrWindowTitle }
        return
    }
    $e = $script:GcrEsc
    try { [Console]::Write("{0}]9;4;0;0{1}" -f $e, [char]7) } catch { }
    try { [Console]::Write("{0}[?25h{0}[?1049l{0}[0m" -f $e) } catch { }
    try { [Console]::CursorVisible = $script:GcrOrigCursor } catch {
        try { [Console]::CursorVisible = $true } catch { }
    }
    try { [Console]::TreatControlCAsInput = $script:GcrOrigTreatCtrlC } catch {
        try { [Console]::TreatControlCAsInput = $false } catch { }
    }
    if (Get-Command Restore-GcrWindowTitle -ErrorAction SilentlyContinue) {
        Restore-GcrWindowTitle
    } else {
        try {
            if ($script:GcrOrigTitle) { [Console]::Title = $script:GcrOrigTitle }
        } catch { }
    }
    Restore-GcrVt
    $script:GcrTui.Active = $false
    $script:GcrTui = $null
}

function Set-GcrTuiTabProgress {
    param([int]$Percent, [int]$State = 1)
    if (-not (Test-GcrTuiActive)) { return }
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $e = $script:GcrEsc
    try { [Console]::Write("{0}]9;4;{1};{2}{3}" -f $e, $State, $Percent, [char]7) } catch { }
}

function Set-GcrTuiRepo {
    param(
        [string]$Url,
        [string]$OutDir,
        [string]$Ref,
        [string]$Commit,
        [switch]$Resume
    )
    if (-not (Test-GcrTuiActive)) { return }
    if ($PSBoundParameters.ContainsKey("Url")) { $script:GcrTui.RepoUrl = $Url }
    if ($PSBoundParameters.ContainsKey("OutDir")) { $script:GcrTui.OutDir = $OutDir }
    if ($PSBoundParameters.ContainsKey("Ref")) { $script:GcrTui.Ref = $Ref }
    if ($PSBoundParameters.ContainsKey("Commit")) { $script:GcrTui.Commit = $Commit }
    if ($Resume) { $script:GcrTui.Resume = $true }
    $script:GcrTui.Dirty = $true
}

function Set-GcrTuiPhase {
    param([string]$Name, [string]$Detail = "")
    # Runs before the TUI check so script (-NoTui) runs also update the title.
    if ($Name -and (Get-Command Update-GcrWindowTitle -ErrorAction SilentlyContinue)) {
        Update-GcrWindowTitle -State $Name
    }
    if (-not (Test-GcrTuiActive)) { return }
    if ($Name) { $script:GcrTui.Phase = $Name }
    if ($PSBoundParameters.ContainsKey("Detail")) { $script:GcrTui.PhaseDetail = $Detail }
    $script:GcrTui.Dirty = $true
    Sync-GcrTuiWindowTitle
}

function Add-GcrTuiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = "INFO"
    )
    if (-not (Test-GcrTuiActive)) { return }
    $msg = [string]$Message
    $msg = $msg -replace "[\r\n]+", " "
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 397) + "..." }
    $entry = @{
        T = Get-Date
        L = [string]$Level
        M = $msg
    }
    [void]$script:GcrTui.Logs.Add($entry)
    while ($script:GcrTui.Logs.Count -gt 400) {
        $script:GcrTui.Logs.RemoveAt(0)
    }
    if ($script:GcrTui.LogOffset -eq 0) { $script:GcrTui.Dirty = $true }
    else { $script:GcrTui.Dirty = $true }
}

function Add-GcrTuiFailure {
    param([string]$Path)
    if (-not (Test-GcrTuiActive)) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    [void]$script:GcrTui.Failures.Add($Path)
    while ($script:GcrTui.Failures.Count -gt 80) {
        $script:GcrTui.Failures.RemoveAt(0)
    }
    $script:GcrTui.Dirty = $true
}

function Add-GcrGitOutput {
    param([string]$Text, [switch]$Progress)
    if (-not (Test-GcrTuiActive)) { return }
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return }
    # A cold batch prints one "unable to read sha1 file of <path> (<oid>)" per
    # missing blob. That is expected (the caller fetches those blobs and then
    # logs a single summary including the first line and the count), so flooding
    # the activity log with them just hides everything else.
    if ($t -match "unable to read sha1 file of") {
        $script:GcrTui.Sha1Noise = [int]$script:GcrTui.Sha1Noise + 1
        return
    }
    if ($t -match "(\d+)\s*%") {
        $script:GcrTui.GitPercent = [int]$Matches[1]
        $script:GcrTui.PhaseDetail = $t
        $script:GcrTui.Dirty = $true
        if ($Progress) { return }
        if ($t -match "Receiving objects|Resolving deltas|Counting objects|Compressing objects|Enumerating") {
            return
        }
    }
    if ($Progress) {
        $script:GcrTui.PhaseDetail = $t
        $script:GcrTui.Dirty = $true
        return
    }
    Add-GcrTuiLog -Level "INFO" -Message $t
}

function Receive-GcrGitBytes {
    param(
        [byte[]]$Buffer,
        [int]$Count,
        [System.Text.StringBuilder]$Carry,
        [switch]$IsStdErr
    )
    if ($Count -le 0 -or $null -eq $Carry) { return }
    $text = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $Count)
    [void]$Carry.Append($text)
    $s = $Carry.ToString()
    $Carry.Length = 0
    $acc = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq [char]13) {
            if ($IsStdErr) { Add-GcrGitOutput -Text $acc.ToString() -Progress }
            [void]$acc.Clear()
        } elseif ($ch -eq [char]10) {
            if ($IsStdErr) { Add-GcrGitOutput -Text $acc.ToString() }
            [void]$acc.Clear()
        } else {
            [void]$acc.Append($ch)
        }
    }
    if ($acc.Length -gt 0) { [void]$Carry.Append($acc.ToString()) }
}

function Update-GcrTuiProgress {
    param(
        [int]$OkCount,
        [int]$TotalCount,
        [int]$FailCount,
        [int64]$DoneBytes,
        [double]$Rate,
        [string]$Eta,
        [string]$CurrentFile,
        [double]$SpeedBps = -1
    )
    if (-not (Test-GcrTuiActive)) { return }
    $script:GcrTui.Ok = $OkCount
    $script:GcrTui.Total = $TotalCount
    $script:GcrTui.Fail = $FailCount
    $script:GcrTui.Bytes = $DoneBytes
    $script:GcrTui.Rate = $Rate
    if ($SpeedBps -ge 0) { $script:GcrTui.Speed = $SpeedBps }
    if ($Eta) { $script:GcrTui.Eta = $Eta }
    if ($PSBoundParameters.ContainsKey("CurrentFile")) { $script:GcrTui.CurrentFile = $CurrentFile }
    $script:GcrTui.Dirty = $true
    $pct = 0
    if ($TotalCount -gt 0) { $pct = [int][Math]::Round(100.0 * $OkCount / $TotalCount) }
    $state = 1
    if ($FailCount -gt 0) { $state = 2 }
    if ($script:GcrTui.Phase -eq "fetch" -and $script:GcrTui.GitPercent -ge 0) {
        $pct = $script:GcrTui.GitPercent
        $state = 1
    }
    Set-GcrTuiTabProgress -Percent $pct -State $state
    Sync-GcrTuiWindowTitle
}

# Keep the taskbar / tab title in step with the dashboard (repo, progress, state).
# The heavy lifting lives in git-clone-resume.ps1 so -NoTui mode gets it too.
function Sync-GcrTuiWindowTitle {
    if (-not (Get-Command Update-GcrWindowTitle -ErrorAction SilentlyContinue)) { return }
    if (-not (Test-GcrTuiActive)) { return }
    # Only override the phase for these terminal states. Anything else keeps the
    # phase picked by Set-GcrTuiPhase, otherwise every progress tick would
    # replace "scanning workspace" / "42%" with a bare "run".
    $state = ""
    if ($script:GcrTui.Status -eq "done") { $state = "done" }
    elseif ($script:GcrTui.Status -eq "error") { $state = "error" }
    elseif ($script:GcrTui.QuitRequested) { $state = "stopped" }
    elseif ($script:GcrTui.Paused) { $state = "paused" }
    if ($state) {
        Update-GcrWindowTitle -State $state -Ok $script:GcrTui.Ok -Total $script:GcrTui.Total -Fail $script:GcrTui.Fail
    } else {
        Update-GcrWindowTitle -Ok $script:GcrTui.Ok -Total $script:GcrTui.Total -Fail $script:GcrTui.Fail
    }
}

function Get-GcrHistoryPath {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [Environment]::GetFolderPath("ApplicationData") }
    return (Join-Path (Join-Path $root "git-clone-resume") "history.json")
}

function Get-GcrSettingsPath {
    $historyPath = Get-GcrHistoryPath
    return (Join-Path (Split-Path -Parent $historyPath) "settings.json")
}

function Get-GcrLanguagePreference {
    try {
        $path = Get-GcrSettingsPath
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $settings = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if ($settings.language -eq "en-US" -or $settings.language -eq "zh-CN") {
            return [string]$settings.language
        }
    } catch { }
    return $null
}

function Save-GcrLanguagePreference {
    param([ValidateSet("zh-CN", "en-US")][string]$Language)
    try {
        $path = Get-GcrSettingsPath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $settings = @{ language = $Language; updated = (Get-Date).ToString("o") }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json $settings), (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

function Set-GcrLanguage {
    param([ValidateSet("zh-CN", "en-US")][string]$Language)
    $script:GcrLanguage = $Language
    Save-GcrLanguagePreference -Language $Language
}

function Get-GcrHistory {
    $path = Get-GcrHistoryPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        return @($parsed)
    } catch {
        return @()
    }
}

function Get-GcrHistoryLast {
    $items = @(Get-GcrHistory)
    if ($items.Count -eq 0) { return $null }
    $partial = @($items | Where-Object { $_.status -eq "partial" -or $_.status -eq "running" -or $_.status -eq "failed" })
    if ($partial.Count -gt 0) { return $partial[0] }
    return $items[0]
}

function Clear-GcrHistory {
    $path = Get-GcrHistoryPath
    $count = @(Get-GcrHistory).Count
    try {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        return $count
    } catch {
        return 0
    }
}

function Remove-GcrHistoryEntry {
    param(
        [string]$Url,
        [string]$OutDir
    )
    $items = New-Object System.Collections.ArrayList
    $removed = $false
    foreach ($it in @(Get-GcrHistory)) {
        $sameDir = ($OutDir -and $it.outDir -and ([string]$it.outDir -eq $OutDir))
        $sameUrl = (-not $OutDir -and $Url -and $it.url -and ([string]$it.url -eq $Url))
        if ($sameDir -or $sameUrl) {
            $removed = $true
            continue
        }
        [void]$items.Add($it)
    }
    if (-not $removed) { return $false }
    $path = Get-GcrHistoryPath
    try {
        if ($items.Count -eq 0) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            return $true
        }
        $json = ConvertTo-Json -InputObject @($items.ToArray()) -Depth 5
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
        return $true
    } catch {
        return $false
    }
}

function Save-GcrHistory {
    param(
        [string]$Url,
        [string]$OutDir,
        [string]$Ref,
        [string]$Commit,
        [string]$Status,
        [int]$Ok = 0,
        [int]$Total = 0,
        [int]$Fail = 0
    )
    if ([string]::IsNullOrWhiteSpace($OutDir) -and [string]::IsNullOrWhiteSpace($Url)) { return }
    $items = New-Object System.Collections.ArrayList
    foreach ($it in @(Get-GcrHistory)) {
        $sameDir = ($it.outDir -and $OutDir -and ([string]$it.outDir -eq $OutDir))
        $sameUrl = ($it.url -and $Url -and ([string]$it.url -eq $Url) -and -not $OutDir)
        if (-not $sameDir -and -not $sameUrl) { [void]$items.Add($it) }
    }
    $entry = @{
        url     = $Url
        outDir  = $OutDir
        ref     = $Ref
        commit  = $Commit
        status  = $Status
        ok      = $Ok
        total   = $Total
        fail    = $Fail
        updated = (Get-Date).ToString("o")
    }
    [void]$items.Insert(0, $entry)
    while ($items.Count -gt 25) { [void]$items.RemoveAt($items.Count - 1) }
    $path = Get-GcrHistoryPath
    $dir = Split-Path -Parent $path
    try {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject @($items.ToArray()) -Depth 5
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

function Format-GcrAgo {
    param($When)
    if ($null -eq $When) { return "" }
    try {
        $dt = [datetime]$When
    } catch { return "" }
    $d = (Get-Date) - $dt
    if ($script:GcrLanguage -eq "en-US") {
        if ($d.TotalSeconds -lt 60) { return "just now" }
        if ($d.TotalMinutes -lt 60) { return ("{0} minutes ago" -f [int]$d.TotalMinutes) }
        if ($d.TotalHours -lt 24) { return ("{0} hours ago" -f [int]$d.TotalHours) }
        return ("{0} days ago" -f [int]$d.TotalDays)
    }
    if ($d.TotalSeconds -lt 60) { return "刚刚" }
    if ($d.TotalMinutes -lt 60) { return ("{0} 分钟前" -f [int]$d.TotalMinutes) }
    if ($d.TotalHours -lt 24) { return ("{0} 小时前" -f [int]$d.TotalHours) }
    return ("{0} 天前" -f [int]$d.TotalDays)
}

function Format-GcrPhaseLabel {
    param([string]$Phase)
    switch ($Phase) {
        "idle"    { return "就绪" }
        "wizard"  { return "设置" }
        "init"    { return "初始化仓库" }
        "fetch"   { return "拉取元数据" }
        "list"    { return "枚举文件树" }
        "scan"    { return "扫描已有文件" }
        "download"{ return "下载文件" }
        "repair"  { return "修复 git index" }
        "done"    { return "完成" }
        "error"   { return "出错" }
        default   { return $Phase }
    }
}

function New-GcrBar {
    param([int]$Width, [double]$Ratio, [switch]$Indeterminate, [int]$Tick)
    $box = $script:GcrTui.Box
    if ($Width -lt 3) { return "" }
    if ($Indeterminate) {
        $pos = 0
        if ($Width -gt 0) { $pos = [Math]::Abs($Tick) % $Width }
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $Width; $i++) {
            $d = [Math]::Abs($i - $pos)
            if ($d -le 2) { [void]$sb.Append($box.BarF) } else { [void]$sb.Append($box.BarE) }
        }
        return $sb.ToString()
    }
    if ($Ratio -lt 0) { $Ratio = 0 }
    if ($Ratio -gt 1) { $Ratio = 1 }
    $filled = [int][Math]::Round($Width * $Ratio)
    if ($filled -gt $Width) { $filled = $Width }
    return (($box.BarF * $filled) + ($box.BarE * ($Width - $filled)))
}

function Out-GcrFrame {
    param([string[]]$Lines)
    if (-not (Test-GcrTuiActive)) { return }
    $e = $script:GcrEsc
    $size = Get-GcrTuiSize
    $h = [int]$size.H
    if ($h -lt 1) { return }
    $rows = New-Object System.Collections.Generic.List[string]
    $nIn = 0
    if ($null -ne $Lines) { $nIn = @($Lines).Count }
    for ($i = 0; $i -lt $h; $i++) {
        if ($i -lt $nIn -and $null -ne $Lines[$i]) { [void]$rows.Add([string]$Lines[$i]) }
        else { [void]$rows.Add("") }
    }
    $prev = @()
    if ($null -ne $script:GcrTui.LastFrame) { $prev = @($script:GcrTui.LastFrame) }
    $full = $true
    if ($prev.Count -eq $h -and [int]$script:GcrTui.LastFrameW -eq [int]$size.W -and [int]$script:GcrTui.LastFrameH -eq $h) {
        $full = $false
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($e).Append("[?25l")
    for ($i = 0; $i -lt $h; $i++) {
        $ln = $rows[$i]
        if (-not $full -and $i -lt $prev.Count -and $ln -eq $prev[$i]) { continue }
        [void]$sb.Append($e).Append("[").Append($i + 1).Append(";1H")
        [void]$sb.Append($ln)
        [void]$sb.Append($e).Append("[K")
    }
    try {
        [Console]::Out.Write($sb.ToString())
        [Console]::Out.Flush()
    } catch { }
    try { [Console]::CursorVisible = $false } catch { }
    $script:GcrTui.LastFrame = $rows.ToArray()
    $script:GcrTui.LastFrameW = [int]$size.W
    $script:GcrTui.LastFrameH = $h
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
# Keyboard and mouse use two different, independent paths, and that separation is
# deliberate:
#
#   * Keyboard goes through the managed [Console]::ReadKey, which is the proven
#     path and keeps working in every host. It is read one key at a time, but a
#     whole burst of already-typed keys is drained per frame by the callers, and
#     that batching (not the read call) is what keeps a held arrow key
#     responsive: Windows auto-repeat fires far faster than a PowerShell frame
#     can be composed, so repainting per event made the queue outlive the
#     keypress and the highlight kept stepping after the key was released.
#
#   * Mouse events are reported only by ReadConsoleInput; the managed API cannot
#     see them at all. That call is used purely to collect clicks, and it is
#     only attempted while mouse reporting has actually been enabled and only
#     when no key is pending - [Console]::ReadKey must stay the one draining keys
#     from the console, or a key could be consumed by the wrong reader. If the
#     native call is unavailable for any reason, clicks are simply unavailable
#     and the keyboard is unaffected.
$script:GcrInputBuf = $null

# Pumps already-queued console events into $script:GcrPendingInput.
#
# Keys come from the managed reader and mouse clicks from ReadConsoleInput. The
# key read happens first and short-circuits the native call, so the two readers
# can never race for the same record.
function Receive-GcrTuiInput {
    # 1. Keys, via the managed path. One per call; callers loop to drain a burst.
    try {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($null -ne $k) { [void]$script:GcrPendingInput.Add($k) }
            return
        }
    } catch { }

    # 2. Mouse, via the native path - only while mouse reporting is on, and only
    #    when no key was pending (checked above).
    if (-not $script:GcrMouseReady) { return }
    Receive-GcrMouseInput
}

# Collects mouse click records. Movement, wheel and button-release records are
# dropped; a release reports an empty button state, so requiring the left button
# to be down keeps one click from being counted twice.
#
# ReadConsoleInput returns keyboard records too, and anything this function takes
# out of the console buffer is gone. Losing a keystroke that way is precisely the
# failure this code must not have, so a key record is a hard error: mouse support
# switches itself off, and the managed reader keeps sole ownership of the
# keyboard. That is the fail-safe: a broken click feature must never cost input.
function Receive-GcrMouseInput {
    if ($null -eq $script:GcrInputBuf) { return }
    try {
        $native = Get-GcrNativeType
        $hIn = $native::GetStdHandle(-10)
        $buf = $script:GcrInputBuf
        $n = [uint32]0
        $guard = 0
        while ($guard -lt 4) {
            if (-not $native::ReadConsoleInput($hIn, $buf, [uint32]$buf.Length, [ref]$n)) { return }
            if ($n -le 0) { return }
            for ($i = 0; $i -lt $n; $i++) {
                if ($buf[$i].EventType -eq $script:GcrInputKeyEvent) {
                    $script:GcrMouseFaults++
                    if ($script:GcrMouseFaults -ge 2) { Disable-GcrMouse }
                    return
                }
                if ($buf[$i].EventType -ne $script:GcrInputMouseEvent) { continue }
                $me = $buf[$i].Event.MouseEvent
                if ($me.dwEventFlags -ne 0) { continue }
                if (([uint32]$me.dwButtonState -band [uint32]$script:GcrFromLeft1stButton) -eq 0) { continue }
                # Holding Shift keeps the terminal's own text selection usable.
                if (([uint32]$me.dwControlKeyState -band [uint32]$script:GcrShiftPressed) -ne 0) { continue }
                [void]$script:GcrPendingInput.Add(@{
                        Kind = "mouse"
                        X    = [int]$me.dwMousePositionX
                        Y    = [int]$me.dwMousePositionY
                        Ctrl = (([uint32]$me.dwControlKeyState -band [uint32]$script:GcrCtrlPressed) -ne 0)
                    })
            }
            if ($n -lt $buf.Length) { return }
            $guard++
        }
    } catch {
        # Any native failure retires mouse support rather than risking the keyboard.
        Disable-GcrMouse
    }
}

# Maps a Win32 KEY_EVENT_RECORD onto the ConsoleKeyInfo shape the rest of the
# TUI already consumes, so Invoke-GcrTuiKey and the wizard need no changes.
function Convert-GcrKeyEvent {
    param($KeyEvent)
    try {
        $vk = [int]$KeyEvent.wVirtualKeyCode
        $ctrlState = [uint32]$KeyEvent.dwControlKeyState
        $mods = [ConsoleModifiers]0
        if (($ctrlState -band [uint32]0x0008) -ne 0 -or ($ctrlState -band [uint32]0x0004) -ne 0) {
            $mods = $mods -bor [ConsoleModifiers]::Control
        }
        if (($ctrlState -band [uint32]0x0010) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Shift }
        if (($ctrlState -band [uint32]0x0001) -ne 0 -or ($ctrlState -band [uint32]0x0002) -ne 0) {
            $mods = $mods -bor [ConsoleModifiers]::Alt
        }
        $key = Convert-GcrVirtualKey -VirtualKey $vk -Modifiers $mods
        $ch = [char]$KeyEvent.UnicodeChar
        # Ctrl+letter reports a control character (0x01-0x1A) in UnicodeChar, but
        # ConsoleKeyInfo carries the plain letter, and Test-GcrCtrlKey compares
        # Key.ToString() against "C"/"V"/"D". Normalise so those keep working.
        if (($mods -band [ConsoleModifiers]::Control) -ne 0 -and [int]$ch -ge 1 -and [int]$ch -le 26) {
            $ch = [char]([int]$ch + 96)
        }
        return New-Object System.ConsoleKeyInfo($ch, $key, (($mods -band [ConsoleModifiers]::Shift) -ne 0), (($mods -band [ConsoleModifiers]::Alt) -ne 0), (($mods -band [ConsoleModifiers]::Control) -ne 0))
    } catch {
        return $null
    }
}

function Convert-GcrVirtualKey {
    param([int]$VirtualKey, $Modifiers)
    # ConsoleKey values are numerically identical to the Win32 virtual-key codes
    # for the range this TUI cares about, so a direct cast is exact. The letters
    # are the exception: VK_A..VK_Z equal 'A'..'Z' (0x41..0x5A) and ConsoleKey
    # agrees, but Ctrl+letter arrives with a control-character UnicodeChar, so the
    # virtual key is the only reliable source for the key itself.
    if ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A) { return [ConsoleKey]$VirtualKey }
    if ($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) { return [ConsoleKey]$VirtualKey }
    switch ($VirtualKey) {
        0x08 { return [ConsoleKey]::Backspace }
        0x09 { return [ConsoleKey]::Tab }
        0x0D { return [ConsoleKey]::Enter }
        0x1B { return [ConsoleKey]::Escape }
        0x20 { return [ConsoleKey]::Spacebar }
        0x21 { return [ConsoleKey]::PageUp }
        0x22 { return [ConsoleKey]::PageDown }
        0x23 { return [ConsoleKey]::End }
        0x24 { return [ConsoleKey]::Home }
        0x25 { return [ConsoleKey]::LeftArrow }
        0x26 { return [ConsoleKey]::UpArrow }
        0x27 { return [ConsoleKey]::RightArrow }
        0x28 { return [ConsoleKey]::DownArrow }
        0x2D { return [ConsoleKey]::Insert }
        0x2E { return [ConsoleKey]::Delete }
        default { }
    }
    if ($VirtualKey -ge 0x70 -and $VirtualKey -le 0x87) { return [ConsoleKey]($VirtualKey - 0x70 + [int][ConsoleKey]::F1) }
    return [ConsoleKey]::NoName
}

# Returns the next *keyboard* event, skipping mouse events. Used by the dashboard
# (keyboard-driven) and by the git-child loop.
function Read-GcrTuiKey {
    param([int]$TimeoutMs = 0)
    $deadline = [Environment]::TickCount + [Math]::Max(0, $TimeoutMs)
    while ($true) {
        while ($script:GcrPendingInput.Count -gt 0) {
            $item = $script:GcrPendingInput[0]
            $script:GcrPendingInput.RemoveAt(0)
            if (Test-GcrMouseEvent $item) { continue }
            if ($null -ne $item) { return $item }
        }
        if ([Environment]::TickCount -ge $deadline) { return $null }
        Receive-GcrTuiInput
        if ($script:GcrPendingInput.Count -eq 0) { Start-Sleep -Milliseconds 1 }
    }
}

# Returns the next event of any kind, so the wizard can react to clicks too.
function Read-GcrTuiInput {
    param([int]$TimeoutMs = 0)
    $deadline = [Environment]::TickCount + [Math]::Max(0, $TimeoutMs)
    while ($true) {
        while ($script:GcrPendingInput.Count -gt 0) {
            $item = $script:GcrPendingInput[0]
            $script:GcrPendingInput.RemoveAt(0)
            if ($null -ne $item) { return $item }
        }
        if ([Environment]::TickCount -ge $deadline) { return $null }
        Receive-GcrTuiInput
        if ($script:GcrPendingInput.Count -eq 0) { Start-Sleep -Milliseconds 1 }
    }
}

# Drains everything already queued (without waiting) into the caller's list, so a
# key-repeat burst is applied as one batch and painted once. Keyboard events are
# taken one call at a time from the managed reader, so this loops until the
# console reports no more keys and no more clicks.
function Receive-GcrTuiInputBatch {
    param([System.Collections.Generic.List[object]]$Sink)
    $guard = 0
    while ($guard -lt 256) {
        $before = $script:GcrPendingInput.Count
        Receive-GcrTuiInput
        if ($script:GcrPendingInput.Count -le $before) { break }
        while ($script:GcrPendingInput.Count -gt 0) {
            $item = $script:GcrPendingInput[0]
            $script:GcrPendingInput.RemoveAt(0)
            [void]$Sink.Add($item)
        }
        $guard++
    }
    return $Sink.Count
}

function Test-GcrMouseEvent {
    param($Item)
    return ($null -ne $Item -and $Item -is [hashtable] -and $Item.Kind -eq "mouse")
}

function Test-GcrCtrlKey {
    param($Key, [string]$Code)
    if ($null -eq $Key) { return $false }
    $ctrl = [int][ConsoleModifiers]::Control
    if (([int]$Key.Modifiers -band $ctrl) -eq 0) { return $false }
    return ($Key.Key.ToString() -eq $Code)
}

function Invoke-GcrTuiKey {
    param($Key)
    if ($null -eq $Key -or -not (Test-GcrTuiActive)) { return }
    if ($script:GcrTui.Screen -eq "result") {
        if ($Key.Key -eq "Enter" -or $Key.Key -eq "Q" -or $Key.Key -eq "Escape") {
            $script:GcrTui.Status = "close"
        }
        return
    }
    if ($script:GcrTui.Help) {
        if ($Key.Key -ne "LeftArrow" -and $Key.Key -ne "RightArrow") {
            $script:GcrTui.Help = $false
            $script:GcrTui.Dirty = $true
        }
        return
    }
    if (Test-GcrCtrlKey -Key $Key -Code "C") {
        Request-GcrTuiQuit
        return
    }
    switch ($Key.Key.ToString()) {
        "Q" { Request-GcrTuiQuit }
        "P" {
            $script:GcrTui.Paused = -not $script:GcrTui.Paused
            $script:GcrTui.Dirty = $true
            Sync-GcrTuiWindowTitle
        }
        "Escape" {
            if ($script:GcrTui.FailView) { $script:GcrTui.FailView = $false }
            else { $script:GcrTui.Paused = -not $script:GcrTui.Paused }
            $script:GcrTui.Dirty = $true
            Sync-GcrTuiWindowTitle
        }
        "Spacebar" {
            if ($script:GcrTui.Paused) { $script:GcrTui.Paused = $false }
            $script:GcrTui.Dirty = $true
            Sync-GcrTuiWindowTitle
        }
        "H" { $script:GcrTui.Help = $true; $script:GcrTui.Dirty = $true }
        "L" {
            Set-GcrLanguage -Language $(if ($script:GcrLanguage -eq "en-US") { "zh-CN" } else { "en-US" })
            $script:GcrTui.Dirty = $true
        }
        "F" { $script:GcrTui.FailView = -not $script:GcrTui.FailView; $script:GcrTui.Dirty = $true }
        "UpArrow" {
            $script:GcrTui.LogOffset = [Math]::Min($script:GcrTui.Logs.Count, $script:GcrTui.LogOffset + 1)
            $script:GcrTui.Dirty = $true
        }
        "DownArrow" {
            $script:GcrTui.LogOffset = [Math]::Max(0, $script:GcrTui.LogOffset - 1)
            $script:GcrTui.Dirty = $true
        }
        "End" { $script:GcrTui.LogOffset = 0; $script:GcrTui.Dirty = $true }
        "Home" {
            $script:GcrTui.LogOffset = [Math]::Max(0, $script:GcrTui.Logs.Count - 1)
            $script:GcrTui.Dirty = $true
        }
        "J" {
            if ($Key.KeyChar -eq "j") {
                $script:GcrTui.LogOffset = [Math]::Max(0, $script:GcrTui.LogOffset - 1)
                $script:GcrTui.Dirty = $true
            }
        }
        "K" {
            if ($Key.KeyChar -eq "k") {
                $script:GcrTui.LogOffset = [Math]::Min($script:GcrTui.Logs.Count, $script:GcrTui.LogOffset + 1)
                $script:GcrTui.Dirty = $true
            }
        }
        default {
            if ($Key.KeyChar -eq "?") { $script:GcrTui.Help = $true; $script:GcrTui.Dirty = $true }
        }
    }
}

function Request-GcrTuiQuit {
    if (-not (Test-GcrTuiActive)) { return }
    if ($script:GcrTui.QuitRequested) {
        $script:GcrTui.ForceQuit = $true
        if ($null -ne $script:GcrCurrentProc) {
            try { $script:GcrCurrentProc.Kill() } catch { }
        }
    } else {
        $script:GcrTui.QuitRequested = $true
        $script:GcrTui.Paused = $false
    }
    $script:GcrTui.Dirty = $true
    Sync-GcrTuiWindowTitle
}

function Invoke-GcrTuiTick {
    param([switch]$Force)
    if (-not (Test-GcrTuiActive)) { return }
    $size = Get-GcrTuiSize
    if ($size.W -ne $script:GcrTui.Width -or $size.H -ne $script:GcrTui.Height) {
        $script:GcrTui.Width = $size.W
        $script:GcrTui.Height = $size.H
        $script:GcrTui.LastFrame = @()
        $script:GcrTui.Dirty = $true
    }
    $guard = 0
    while ($guard -lt 8) {
        $k = Read-GcrTuiKey -TimeoutMs 0
        if ($null -eq $k) { break }
        Invoke-GcrTuiKey -Key $k
        $guard++
    }
    $now = Get-Date
    $ms = 1000
    try { $ms = ($now - $script:GcrTui.LastDraw).TotalMilliseconds } catch { $ms = 1000 }
    $anim = ($script:GcrTui.Phase -in @("fetch", "init", "list", "scan"))
    $need = [bool]$Force -or [bool]$script:GcrTui.Dirty -or ($anim -and $ms -ge 80)
    if ($need -and $ms -ge 16) {
        Render-GcrTui
        $script:GcrTui.Dirty = $false
        $script:GcrTui.LastDraw = $now
        $script:GcrTui.Tick++
    }
}

function Wait-GcrTuiPaused {
    if (-not (Test-GcrTuiActive)) { return }
    while ($script:GcrTui.Paused -and -not $script:GcrTui.QuitRequested) {
        Invoke-GcrTuiTick
        Start-Sleep -Milliseconds 16
    }
}

# ---------------------------------------------------------------------------
# Frame composition
# ---------------------------------------------------------------------------
# These helpers used to be nested functions *inside* Render-GcrTui and
# Render-GcrTuiWizard. PowerShell re-parses and re-compiles a nested function on
# every call of its parent, so the render loop was rebuilding four function
# definitions per frame. They now live at script scope and share the frame being
# built through $script:GcrFrame, set up once per render.
#
# $lines is the List[string] the renderer appends to and finally hands to
# Out-GcrFrame, so callers can read $lines.Count to know how many rows they have
# consumed instead of re-measuring the frame. Frame state is created fresh by
# Start-GcrFrame on every render and the palettes are cached per process, so
# nothing here needs initializing at file scope.
$script:GcrFramePalettes = @{}

function Start-GcrFrame {
    param([int]$Width, [int]$Inner, $Box, $Palette)
    $script:GcrFrame = @{
        Lines   = New-Object System.Collections.Generic.List[string]
        Box     = $Box
        Inner   = $Inner
        Width   = $Width
        Palette = $Palette
    }
}

# One palette per screen variant, built on first use. This replaced a per-frame
# hashtable plus nine Get-GcrColor calls (each a function call containing a
# switch).
function Get-GcrFramePalette {
    param([string]$Variant = "dash")
    $cached = $script:GcrFramePalettes[$Variant]
    if ($null -ne $cached) { return $cached }
    $p = @{
        R   = Get-GcrColor "reset"
        B   = Get-GcrColor "bold"
        D   = Get-GcrColor "dim"
        C   = Get-GcrColor "cyan"
        G   = Get-GcrColor "green"
        Y   = Get-GcrColor "yellow"
        E   = Get-GcrColor "red"
        W   = Get-GcrColor "white"
        REV = Get-GcrColor "rev"
    }
    if ($Variant -eq "dash") { $p.T = Get-GcrColor "teal" }
    $script:GcrFramePalettes[$Variant] = $p
    return $p
}

function Push-GcrBorder {
    param([string]$Kind)
    $f = $script:GcrFrame
    $box = $f.Box
    $ch = $box.H
    if ($Kind -eq "top") { $plain = $box.TL + ($ch * $f.Inner) + $box.TR }
    elseif ($Kind -eq "bot") { $plain = $box.BL + ($ch * $f.Inner) + $box.BR }
    else { $plain = $box.L + ($ch * $f.Inner) + $box.R }
    [void]$f.Lines.Add($f.Palette.D + (Format-GcrCell -Text $plain -Width $f.Width) + $f.Palette.R)
}

function Push-GcrRow {
    param([string]$Left, [string]$Right = "", [string]$Color = "")
    $f = $script:GcrFrame
    $box = $f.Box
    $c = $f.Palette
    if (-not $Color) { $Color = $c.W }
    $Left = Convert-GcrText $Left
    $Right = Convert-GcrText $Right
    $leftW = Get-GcrDisplayWidth $Left
    $rightW = Get-GcrDisplayWidth $Right
    $gap = $f.Inner - $leftW - $rightW
    if ($gap -lt 1) {
        $keep = [Math]::Max(8, $f.Inner - $rightW - 1)
        $Left = Truncate-GcrDisplay -Text $Left -Width $keep
        $leftW = Get-GcrDisplayWidth $Left
        $gap = $f.Inner - $leftW - $rightW
        if ($gap -lt 0) { $Right = ""; $rightW = 0; $gap = $f.Inner - $leftW }
        if ($gap -lt 0) { $gap = 0 }
    }
    $body = $Left + (" " * $gap) + $Right
    $v = $box.V
    [void]$f.Lines.Add($c.D + $v + $c.R + $Color + $body + $c.R + $c.D + $v + $c.R)
}

function Get-GcrDashGuide {
    if ($script:GcrTui.Help) { return "快捷键说明。任意键关闭此帮助。" }
    if ($script:GcrTui.FailView) { return "失败文件列表。F 返回活动日志，再次运行同一命令会重试。" }
    if ($script:GcrTui.Screen -eq "result") { return "本次运行已结束。Enter 关闭界面，进度保留在 .git/partial-resume/。" }
    if ($script:GcrTui.QuitRequested) { return "将在当前 git 命令结束后停止。Ctrl+C 再按一次立即结束。" }
    if ($script:GcrTui.Paused) { return "已暂停：当前批次结束后停住。Space 继续，Q 停止。" }
    switch ($script:GcrTui.Phase) {
        "init"     { return "初始化本地仓库并配置 partial clone（只拉元数据，不拉文件内容）。" }
        "fetch"    { return "正在拉取 commit/tree 元数据（blob:none）。文件内容会在下一步按批下载。" }
        "list"     { return "枚举仓库文件树。不会为了拿大小去拉全部 blob。" }
        "scan"     { return "扫描工作区，跳过已经落盘的文件，其余进入待下载队列。" }
        "download" { return "按批 checkout 文件。中断后重跑同一命令即可续传。" }
        "repair"   { return "修复 Windows 上可能被弄乱的 git index。" }
        "done"     { return "全部完成。工作区已可用。" }
        "error"    { return "出错或未完成。重新运行同一命令即可从断点继续。" }
        default    { return "断点续传克隆。Q 停止  ·  P 暂停  ·  ? 帮助" }
    }
}

function Get-GcrWizardGuide {
    param($St)
    if ($St.ConfirmQuit) { return "退出向导？未开始的克隆不会写入进度。Enter 确定，Esc 取消。" }
    if ($St.ConfirmClearAll) { return "清空全部历史记录？不会删除仓库或 .git/partial-resume 进度。Enter 确定，Esc 取消。" }
    if ($St.ConfirmClearOne) { return "删除这条历史记录？不会删除仓库本身。Enter 确定，Esc 取消。" }
    if ($St.Edit) { return "正在编辑。Enter 确认，Esc 取消，Ctrl+V 粘贴。光标用 ← → Home End。" }
    if ($St.Focus -eq "recent") { return "最近任务。Enter 填入 URL/目录/分支，可直接续传未完成的克隆。" }
    $items = Get-GcrWizardItems -St $St
    $sel = [int]$St.Sel
    if ($sel -ge 0 -and $sel -lt $items.Count) {
        $g = [string]$items[$sel].Guide
        if ($g) { return $g }
    }
    return "↑↓ 选择选项，Enter 编辑或开始。每个选项的说明会显示在这一行。"
}

function Render-GcrTui {
    if (-not (Test-GcrTuiActive)) { return }
    if ($script:GcrTui.Screen -eq "wizard") { return }
    $size = Get-GcrTuiSize
    $w = $size.DrawW
    $h = $size.H
    $script:GcrTui.Width = $size.W
    $script:GcrTui.Height = $h
    $c = Get-GcrFramePalette "dash"
    $box = $script:GcrTui.Box
    $inner = [Math]::Max(10, $w - 2)
    Start-GcrFrame -Width $w -Inner $inner -Box $box -Palette $c
    $lines = $script:GcrFrame.Lines

    $badge = "RUN"
    $badgeC = $c.C
    if ($script:GcrTui.Resume) { $badge = "RESUME" }
    if ($script:GcrTui.Paused) { $badge = "PAUSED"; $badgeC = $c.Y }
    if ($script:GcrTui.QuitRequested) { $badge = "STOPPING"; $badgeC = $c.Y }
    if ($script:GcrTui.Status -eq "done") { $badge = "DONE"; $badgeC = $c.G }
    if ($script:GcrTui.Status -eq "error") { $badge = "ERROR"; $badgeC = $c.E }
    if ($script:GcrTui.ForceQuit) { $badge = "KILLED"; $badgeC = $c.E }

    Push-GcrBorder "top"
    $title = " git-clone-resume"
    if (Get-Command Get-GcrVersion -ErrorAction SilentlyContinue) {
        try { $title = $title + " v" + (Get-GcrVersion) } catch { }
    }
    $sub = $badge + " "
    Push-GcrRow -Left ($title) -Right $sub -Color ($c.B + $c.C)
    Push-GcrBorder "mid"

    $compact = ($h -lt 16)
    if (-not $compact) {
        Push-GcrRow -Left (" 仓库  " + $(if ($script:GcrTui.RepoUrl) { $script:GcrTui.RepoUrl } else { "-" })) -Color $c.W
        Push-GcrRow -Left (" 目录  " + $(if ($script:GcrTui.OutDir) { $script:GcrTui.OutDir } else { "-" })) -Color $c.D
        $sha = $script:GcrTui.Commit
        if ($sha.Length -gt 12) { $sha = $sha.Substring(0, 12) }
        $refLine = " 引用  " + $(if ($script:GcrTui.Ref) { $script:GcrTui.Ref } else { "HEAD" })
        if ($sha) { $refLine = $refLine + "   commit " + $sha }
        Push-GcrRow -Left $refLine -Color $c.D
        $phase = Format-GcrPhaseLabel $script:GcrTui.Phase
        $detail = $script:GcrTui.PhaseDetail
        Push-GcrRow -Left (" 阶段  " + $phase) -Right $detail -Color $c.C
        Push-GcrBorder "mid"
    }

    $ratio = 0.0
    $pctText = "0%"
    $indet = $false
    if ($script:GcrTui.Phase -eq "fetch" -and $script:GcrTui.GitPercent -ge 0) {
        $ratio = $script:GcrTui.GitPercent / 100.0
        $pctText = ("{0}%" -f $script:GcrTui.GitPercent)
    } elseif ($script:GcrTui.Total -gt 0) {
        $ratio = $script:GcrTui.Ok / [double]$script:GcrTui.Total
        $pctText = ("{0:N1}%" -f (100.0 * $ratio))
    } elseif ($script:GcrTui.Phase -in @("fetch", "init", "list")) {
        $indet = $true
        $pctText = "..."
    }
    $barW = [Math]::Max(10, $inner - 12)
    $bar = New-GcrBar -Width $barW -Ratio $ratio -Indeterminate:$indet -Tick $script:GcrTui.Tick
    $barColor = $c.G
    if ($script:GcrTui.Fail -gt 0) { $barColor = $c.Y }
    if ($script:GcrTui.Status -eq "error") { $barColor = $c.E }
    Push-GcrRow -Left (" " + $bar) -Right $pctText -Color $barColor

    $bytes = ""
    try { $bytes = Format-Bytes ([int64]$script:GcrTui.Bytes) } catch { $bytes = [string]$script:GcrTui.Bytes }
    $speed = "--"
    try {
        if ([double]$script:GcrTui.Speed -ge 1) { $speed = (Format-Bytes ([int64]$script:GcrTui.Speed)) + "/s" }
    } catch { $speed = "--" }
    # 100.0%  12.3 MB  1.25 MB/s  4.2 files/s  ETA 00:01:20
    $stats = (" {0}/{1}  失败 {2}  {3}  {4}  {5:N1} files/s  ETA {6}" -f @(
            $script:GcrTui.Ok,
            $script:GcrTui.Total,
            $script:GcrTui.Fail,
            $bytes,
            $speed,
            $script:GcrTui.Rate,
            $script:GcrTui.Eta
        ))
    Push-GcrRow -Left $stats -Color $c.W
    if (-not $compact) {
        $cur = $script:GcrTui.CurrentFile
        if (-not $cur) { $cur = "-" }
        Push-GcrRow -Left (" 当前  " + $cur) -Color $c.D
    }

    $footerReserve = 4
    $used = $lines.Count
    $activityH = $h - $used - $footerReserve
    if ($activityH -lt 0) { $activityH = 0 }

    if ($activityH -gt 0) {
        Push-GcrBorder "mid"
        $activityH = $h - $lines.Count - $footerReserve
        if ($activityH -lt 1) { $activityH = 1 }

        $bodyLines = New-Object System.Collections.ArrayList
        if ($script:GcrTui.Screen -eq "result" -and @($script:GcrTui.ResultBody).Count -gt 0) {
            # Result panel: headline in bold green/red, body lines coloured by
            # meaning (success / failure / path / hint) instead of uniform dim.
            $headline = [string]$script:GcrTui.ResultTitle
            if ($headline) {
                $headColor = $c.G
                if ($script:GcrTui.Status -eq "error") { $headColor = $c.E }
                [void]$bodyLines.Add(@{ L = "R"; M = $headline; T = $null; C = ($c.B + $headColor) })
                [void]$bodyLines.Add(@{ L = "R"; M = ""; T = $null; C = $c.D })
            }
            foreach ($b in @($script:GcrTui.ResultBody)) {
                $kind = Get-GcrResultLineKind -Text ([string]$b)
                $col = $c.W
                switch ($kind) {
                    "ok"   { $col = ($c.B + $c.G) }
                    "warn" { $col = $c.Y }
                    "err"  { $col = $c.E }
                    "path" { $col = $c.C }
                    "dim"  { $col = $c.D }
                }
                [void]$bodyLines.Add(@{ L = "R"; M = [string]$b; T = $null; C = $col })
            }
        } elseif ($script:GcrTui.Help) {
            foreach ($b in @(
                    "键盘",
                    "  Q / Ctrl+C   停止（当前 git 命令结束后生效；再按一次强制结束）",
                    "  P / Esc      当前批次结束后暂停",
                    "  Space        从暂停恢复",
                    "  F            切换失败文件列表",
                    "  Up/Down j k  滚动活动日志",
                    "  End          跟随最新日志",
                    "  ? / H        打开或关闭本帮助",
                    "",
                    "续传：重新运行同一条命令。进度在 .git/partial-resume/",
                    "脚本模式：加 -NoTui。强制界面：加 -Tui。"
                )) {
                [void]$bodyLines.Add(@{ L = "INFO"; M = $b; T = $null })
            }
        } elseif ($script:GcrTui.FailView) {
            if ($script:GcrTui.Failures.Count -eq 0) {
                [void]$bodyLines.Add(@{ L = "INFO"; M = "暂无失败文件。"; T = $null })
            } else {
                foreach ($f in $script:GcrTui.Failures) {
                    [void]$bodyLines.Add(@{ L = "ERROR"; M = $f; T = $null })
                }
            }
        } else {
            foreach ($e in $script:GcrTui.Logs) { [void]$bodyLines.Add($e) }
        }

        $view = @($bodyLines)
        $n = $view.Count
        $off = [int]$script:GcrTui.LogOffset
        $end = $n - $off
        if ($end -lt 0) { $end = 0 }
        $start = $end - $activityH
        if ($start -lt 0) { $start = 0 }
        for ($row = 0; $row -lt $activityH; $row++) {
            $idx = $start + $row
            if ($idx -ge $end) {
                Push-GcrRow -Left "" -Color $c.D
                continue
            }
            $item = $view[$idx]
            $prefix = ""
            if ($item.T) { $prefix = ([datetime]$item.T).ToString("HH:mm:ss") + " " }
            $lvl = [string]$item.L
            if (-not $lvl) { $lvl = "INFO" }
            $text = $prefix + $item.M
            $rowColor = Get-GcrLevelColor $lvl
            if ($item.ContainsKey("C")) {
                # per-line override (result panel, where the level is not enough)
                $customColor = [string]$item.C
                if ($customColor) { $rowColor = $customColor }
            }
            Push-GcrRow -Left (" " + $text) -Color $rowColor
        }
    }

    Push-GcrBorder "mid"
    $guide = Get-GcrDashGuide
    Push-GcrRow -Left (" " + $guide) -Color $c.C
    $hint = ""
    if ($script:GcrTui.Screen -eq "result") {
        $hint = " Enter 关闭  ·  Q 退出  ·  ? 帮助"
    } elseif ($script:GcrTui.Help) {
        $hint = " 任意键关闭帮助"
    } elseif ($script:GcrTui.QuitRequested) {
        $hint = " Ctrl+C 再按一次强制结束  ·  ? 帮助"
    } elseif ($script:GcrTui.Paused) {
        $hint = " Space 继续  ·  Q 停止  ·  ? 帮助"
    } else {
        $hint = " Q 停止  ·  P 暂停  ·  F 失败  ·  ? 帮助  ·  ↑↓ 日志"
    }
    $hintColor = $c.D
    if ($script:GcrTui.Paused -or $script:GcrTui.QuitRequested) { $hintColor = $c.Y }
    Push-GcrRow -Left $hint -Color $hintColor
    Push-GcrBorder "bot"

    while ($lines.Count -gt $h) { $lines.RemoveAt($lines.Count - 1) }
    while ($lines.Count -lt $h) { [void]$lines.Add("") }
    Out-GcrFrame -Lines $lines.ToArray()
}

function Show-GcrTuiResult {
    param(
        [string]$Title,
        [string[]]$Body,
        [ValidateSet("done", "error")]
        [string]$Kind = "done"
    )
    if (-not (Test-GcrTuiActive)) { return }
    $script:GcrTui.Screen = "result"
    $script:GcrTui.Status = $Kind
    $script:GcrTui.Phase = $(if ($Kind -eq "done") { "done" } else { "error" })
    $script:GcrTui.ResultTitle = $Title
    $script:GcrTui.ResultBody = @($Body)
    $script:GcrTui.Help = $false
    $script:GcrTui.Paused = $false
    Sync-GcrTuiWindowTitle
    Add-GcrTuiLog -Level $(if ($Kind -eq "done") { "OK" } else { "ERROR" }) -Message $Title
    $script:GcrTui.Dirty = $true
    $pct = 100
    if ($script:GcrTui.Total -gt 0) {
        $pct = [int][Math]::Round(100.0 * $script:GcrTui.Ok / $script:GcrTui.Total)
    }
    $state = 1
    if ($Kind -eq "error") { $state = 2 }
    Set-GcrTuiTabProgress -Percent $pct -State $state
    Render-GcrTui
    $waited = 0
    while ($waited -lt 3600000) {
        $k = Read-GcrTuiKey -TimeoutMs 16
        if ($null -ne $k) {
            if ($k.Key -eq "Enter" -or $k.Key -eq "Q" -or $k.Key -eq "Escape" -or (Test-GcrCtrlKey $k "C")) {
                break
            }
            if ($k.KeyChar -eq "?") { $script:GcrTui.Help = -not $script:GcrTui.Help; Render-GcrTui }
        }
        $waited += 16
        $size = Get-GcrTuiSize
        if ($size.W -ne $script:GcrTui.Width -or $size.H -ne $script:GcrTui.Height) {
            $script:GcrTui.LastFrame = @()
            Render-GcrTui
        }
    }
}

function Test-GcrRepoUrlText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $s = $Text.Trim()
    if ($s -match "\s") { return $false }
    if ($s -match "^(https?|git|ssh)://") { return $true }
    if ($s -match "^[\w.-]+@[\w.-]+:") { return $true }
    if ($s -match "\.git$") { return $true }
    if ($s -match "^(github\.com|gitlab\.com|gitee\.com|bitbucket\.org)[/:]") { return $true }
    if ($s -match "^[A-Za-z]:[\\/]") { return $true }
    if ($s -match "^\\\\") { return $true }
    return $false
}

function Get-GcrFolderNameSafe {
    param([string]$Url)
    if (Get-Command Get-RepoFolderName -ErrorAction SilentlyContinue) {
        return Get-RepoFolderName -Url $Url
    }
    $s = $Url.Trim().TrimEnd([char]47, [char]92)
    if ($s.Length -ge 4 -and $s.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(0, $s.Length - 4)
    }
    $s = $s.Replace([char]92, [char]47)
    $i = $s.LastIndexOf([char]47)
    if ($i -ge 0) { $s = $s.Substring($i + 1) }
    if ([string]::IsNullOrWhiteSpace($s)) { return "repo" }
    return $s
}

function Get-GcrClipboardText {
    try {
        $t = Get-Clipboard -Raw -ErrorAction Stop
        if ($null -eq $t) { return "" }
        return ([string]$t).Trim()
    } catch { return "" }
}

function Convert-GcrWizardResult {
    param($St)
    $include = New-Object System.Collections.Generic.List[string]
    $exclude = New-Object System.Collections.Generic.List[string]
    $incText = ""
    $excText = ""
    try { $incText = [string]$St.Include } catch { }
    try { $excText = [string]$St.Exclude } catch { }
    if (-not [string]::IsNullOrWhiteSpace($incText)) {
        foreach ($p in @($incText -split "[,;]")) {
            $t = $p.Trim()
            if ($t) { [void]$include.Add($t) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($excText)) {
        foreach ($p in @($excText -split "[,;]")) {
            $t = $p.Trim()
            if ($t) { [void]$exclude.Add($t) }
        }
    }
    $depth = $null
    $depthText = ""
    try { $depthText = [string]$St.Depth } catch { }
    if ($depthText -match "^\d+$") { $depth = [int]$depthText }
    $url = ""
    try { $url = ([string]$St.Url).Trim() } catch { }
    $dir = ""
    try { $dir = [string]$St.OutDir } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-GcrFolderNameSafe -Url $url }
    $ref = "HEAD"
    try {
        if ($St.Ref) { $ref = ([string]$St.Ref).Trim() }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($ref)) { $ref = "HEAD" }
    $batch = 32
    $retries = 8
    try { if ($St.BatchSize) { $batch = [int]$St.BatchSize } } catch { }
    try { if ($St.MaxRetries) { $retries = [int]$St.MaxRetries } } catch { }
    if ($batch -lt 1) { $batch = 32 }
    if ($retries -lt 1) { $retries = 8 }
    $obj = New-Object psobject
    Add-Member -InputObject $obj -NotePropertyName RepoUrl -NotePropertyValue $url
    Add-Member -InputObject $obj -NotePropertyName OutDir -NotePropertyValue $dir
    Add-Member -InputObject $obj -NotePropertyName Ref -NotePropertyValue $ref
    Add-Member -InputObject $obj -NotePropertyName BatchSize -NotePropertyValue $batch
    Add-Member -InputObject $obj -NotePropertyName MaxRetries -NotePropertyValue $retries
    Add-Member -InputObject $obj -NotePropertyName Include -NotePropertyValue $include.ToArray()
    Add-Member -InputObject $obj -NotePropertyName Exclude -NotePropertyValue $exclude.ToArray()
    Add-Member -InputObject $obj -NotePropertyName Depth -NotePropertyValue $depth
    Add-Member -InputObject $obj -NotePropertyName Verify -NotePropertyValue ([bool]$St.Verify)
    Add-Member -InputObject $obj -NotePropertyName ForceRefetch -NotePropertyValue ([bool]$St.ForceRefetch)
    Add-Member -InputObject $obj -NotePropertyName DryRun -NotePropertyValue ([bool]$St.DryRun)
    Add-Member -InputObject $obj -NotePropertyName Language -NotePropertyValue ([string]$St.Language)
    return ,$obj
}

function ConvertFrom-GcrWizardOutput {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    foreach ($x in @($Raw)) {
        if ($null -eq $x) { continue }
        if ($x -is [hashtable]) {
            if ($x.ContainsKey("RepoUrl")) { return $x }
            continue
        }
        try {
            if ($null -ne $x.PSObject.Properties["RepoUrl"]) { return $x }
        } catch { }
    }
    return $null
}

# Wizard rows are built with the same frame state as the dashboard, so the
# row/border helpers are shared instead of being redefined on every render.
function WBorder {
    param([string]$Kind)
    Push-GcrBorder -Kind $Kind
}

function WRow {
    param([string]$Text, [string]$Color, [switch]$Sel)
    $f = $script:GcrFrame
    $c = $f.Palette
    if (-not $Color) { $Color = $c.W }
    $Text = Convert-GcrText $Text
    $body = Format-GcrCell -Text $Text -Width $f.Inner
    if ($Sel) { $Color = $c.REV + $Color }
    $v = $f.Box.V
    [void]$f.Lines.Add($c.D + $v + $c.R + $Color + $body + $c.R + $c.D + $v + $c.R)
}

function Render-GcrTuiWizard {
    param($St)
    $size = Get-GcrTuiSize
    $w = $size.DrawW
    $h = $size.H
    $inner = [Math]::Max(10, $w - 2)
    $c = Get-GcrFramePalette "wizard"
    $box = $script:GcrTui.Box
    Start-GcrFrame -Width $w -Inner $inner -Box $box -Palette $c
    $lines = $script:GcrFrame.Lines

    $items = Get-GcrWizardItems -St $St
    WBorder "top"
    $ver = ""
    if (Get-Command Get-GcrVersion -ErrorAction SilentlyContinue) {
        try { $ver = "v" + (Get-GcrVersion) } catch { $ver = "" }
    }
    WRow " git-clone-resume" ($c.B + $c.C)
    $sub = " 断点续传克隆  ·  partial clone + 按批 checkout"
    if ($ver) { $sub = $sub + "  " + $ver }
    WRow $sub $c.D
    WBorder "mid"

    $formEnd = 12
    $recent = @($St.Recent)
    $maxFormVisible = [Math]::Max(6, $h - 10)
    if ($maxFormVisible -gt ($formEnd + 1)) { $maxFormVisible = $formEnd + 1 }
    $sel = [int]$St.Sel
    $top = [int]$St.Scroll
    if ($sel -le $formEnd) {
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge $top + $maxFormVisible) { $top = $sel - $maxFormVisible + 1 }
        if ($top -lt 0) { $top = 0 }
        $St.Scroll = $top
    }
    # Rows the user can click, rebuilt on every render: terminal row
    # number (1-based) -> the wizard action for that row.
    $clickable = @{}
    $end = [Math]::Min($formEnd, $top + $maxFormVisible - 1)
    for ($i = $top; $i -le $end; $i++) {
        $it = $items[$i]
        $mark = "  "
        if ($sel -eq $i) { $mark = " " + $script:GcrTui.Box.Pointer }
        $val = [string]$it.Value
        if ($it.Kind -eq "bool") {
            if ($script:GcrLanguage -eq "en-US") { $val = $(if ($it.Flag) { "On" } else { "Off" }) }
            else { $val = $(if ($it.Flag) { "开" } else { "关" }) }
        }
        if ($St.Edit -and $sel -eq $i) {
            $buf = [string]$St.EditBuf
            $cur = [int]$St.EditCur
            if ($cur -lt 0) { $cur = 0 }
            if ($cur -gt $buf.Length) { $cur = $buf.Length }
            $val = $buf.Insert($cur, "|")
        }
        $labelText = Convert-GcrText ([string]$it.Label)
        $label = Format-GcrCell $labelText 20
        $text = $mark + " " + $label + " " + $val
        $col = $c.W
        if ($it.Kind -eq "start") { $col = $c.G + $c.B }
        # Remember which terminal row this item occupies.
        $rowIndex = $lines.Count
        WRow $text $col -Sel:($sel -eq $i -and -not $St.Edit)
        $clickable[$rowIndex + 1] = @{ Kind = "item"; Index = $i; Id = [string]$it.Id }
    }

    WBorder "mid"
    $recentSlots = $h - $lines.Count - 5
    if ($recentSlots -lt 1) { $recentSlots = 1 }
    $recentTop = [int]$St.RecentTop
    $maxRecentTop = [Math]::Max(0, $recent.Count - $recentSlots)
    if ($recentTop -gt $maxRecentTop) { $recentTop = $maxRecentTop; $St.RecentTop = $recentTop }
    if ($St.Focus -eq "recent") {
        if ($St.RecentSel -lt $recentTop) { $recentTop = [int]$St.RecentSel; $St.RecentTop = $recentTop }
        if ($St.RecentSel -ge $recentTop + $recentSlots) {
            $recentTop = [int]$St.RecentSel - $recentSlots + 1
            $St.RecentTop = $recentTop
        }
    }
    $recentTitle = " 最近任务  (Tab 切换  ·  Enter 填入  ·  Del 删除)"
    if ($recent.Count -gt $recentSlots) {
        $visibleEnd = [Math]::Min($recent.Count, $recentTop + $recentSlots)
        $recentTitle = $recentTitle + ("  [{0}-{1}/{2}]" -f ($recentTop + 1), $visibleEnd, $recent.Count)
    }
    WRow $recentTitle $c.D
    if ($recent.Count -eq 0) {
        WRow "    （无。完成一次克隆后会出现在这里）" $c.D
        $recentSlots--
    } else {
        $show = [Math]::Min($recent.Count - $recentTop, [Math]::Max(1, $recentSlots))
        for ($slot = 0; $slot -lt $show; $slot++) {
            $r = $recentTop + $slot
            $it = $recent[$r]
            $name = [string]$it.outDir
            if ($name) { $name = Split-Path -Leaf $name }
            if (-not $name) { $name = [string]$it.url }
            $pct = ""
            try {
                if ([int]$it.total -gt 0) { $pct = ("{0}%" -f [int](100 * [int]$it.ok / [int]$it.total)) }
            } catch { }
            $stt = [string]$it.status
            $ago = ""
            try { $ago = Format-GcrAgo $it.updated } catch { }
            $mark = "    "
            $isSel = ($St.Focus -eq "recent" -and [int]$St.RecentSel -eq $r)
            if ($isSel) { $mark = "  " + $script:GcrTui.Box.Pointer + " " }
            $text = $mark + $name + "  " + $stt + " " + $pct + "  " + $ago
            $rowIndex = $lines.Count
            WRow $text $(if ($isSel) { $c.C } else { $c.D }) -Sel:$isSel
            $clickable[$rowIndex + 1] = @{ Kind = "recent"; Index = $r }
            $recentSlots--
        }
    }
    while ($recentSlots -gt 0) { WRow "" $c.D; $recentSlots-- }

    WBorder "mid"
    $guide = Get-GcrWizardGuide -St $St
    if ($St.Error) { $guide = [string]$St.Error }
    $guideColor = $c.C
    if ($St.Error) { $guideColor = $c.E }
    if ($St.ConfirmQuit -or $St.ConfirmClearAll -or $St.ConfirmClearOne) { $guideColor = $c.Y }
    WRow (" " + $guide) $guideColor
    $foot = " Enter 编辑/开始  ·  Ctrl+S 开始克隆  ·  Space 开关  ·  ←→ 改批次  ·  Q 退出"
    if ($St.Edit) { $foot = " Enter 确认  ·  Ctrl+S 开始克隆  ·  Esc 取消" }
    if ($St.ConfirmQuit) { $foot = " Enter 确定退出  ·  Esc 返回" }
    if ($St.ConfirmClearAll -or $St.ConfirmClearOne) { $foot = " Enter 确定  ·  Esc 取消" }
    if ($St.Focus -eq "recent" -and -not $St.ConfirmQuit -and -not $St.ConfirmClearAll -and -not $St.ConfirmClearOne -and -not $St.Edit) {
        $foot = " Enter 填入  ·  Ctrl+S 开始克隆  ·  Del 删除  ·  Tab 返回  ·  Q 退出"
    }
    WRow $foot $c.D
    WBorder "bot"
    while ($lines.Count -gt $h) { $lines.RemoveAt($lines.Count - 1) }
    while ($lines.Count -lt $h) { [void]$lines.Add("") }
    $script:GcrMouseHit = $clickable
    Out-GcrFrame -Lines $lines.ToArray()
}

function Get-GcrWizardItems {
    param($St)
    return @(
        @{ Id = "url";     Kind = "text";  Label = "仓库 URL";    Value = $St.Url; Flag = $false; Guide = "远程仓库地址，支持 https、ssh、git@ 以及本地路径。Ctrl+V 从剪贴板粘贴。" }
        @{ Id = "dir";     Kind = "text";  Label = "本地目录";    Value = $(if ($St.OutDir) { $St.OutDir } else { "(自动)" }); Flag = $false; Guide = "工作区目录。留空则用仓库名。已有 .git/partial-resume 时自动续传。" }
        @{ Id = "ref";     Kind = "text";  Label = "分支/标签";   Value = $St.Ref; Flag = $false; Guide = "分支、标签或 commit SHA。默认远程 HEAD。" }
        @{ Id = "batch";   Kind = "enum";  Label = "每批文件";    Value = [string]$St.BatchSize; Flag = $false; Guide = "每批 checkout 的文件数。越大越快，中断粒度越粗。← → 调整。" }
        @{ Id = "retry";   Kind = "enum";  Label = "重试次数";    Value = [string]$St.MaxRetries; Flag = $false; Guide = "单文件失败后的最大重试次数。← → 调整。网络不稳时可调大。" }
        @{ Id = "include"; Kind = "text";  Label = "只含路径";    Value = $(if ($St.Include) { $St.Include } else { "(全部)" }); Flag = $false; Guide = "只下载匹配的路径，逗号分隔通配符，例如 src/*,docs/*。空表示全部。" }
        @{ Id = "exclude"; Kind = "text";  Label = "排除路径";    Value = $(if ($St.Exclude) { $St.Exclude } else { "(无)" }); Flag = $false; Guide = "跳过匹配的路径，例如 *.bin,*.zip。可与「只含路径」同时使用。" }
        @{ Id = "depth";   Kind = "text";  Label = "浅克隆深度";  Value = $(if ($St.Depth) { $St.Depth } else { "(完整历史)" }); Flag = $false; Guide = "浅克隆深度。留空则拉完整 commit 历史（仍然不拉 blob）。" }
        @{ Id = "verify";  Kind = "bool";  Label = "哈希校验";    Value = ""; Flag = [bool]$St.Verify; Guide = "续传时对已有文件做 hash-object 校验，哈希不一致则重新下载。Space 开关。" }
        @{ Id = "force";   Kind = "bool";  Label = "强制 refetch"; Value = ""; Flag = [bool]$St.ForceRefetch; Guide = "强制重新 fetch 目标 ref。换分支或更新到最新 commit 时打开。Space 开关。" }
        @{ Id = "dry";     Kind = "bool";  Label = "DryRun";     Value = ""; Flag = [bool]$St.DryRun; Guide = "只列出将要处理的文件，不下载 blob。适合先看清单。Space 开关。" }
        @{ Id = "language"; Kind = "enum"; Label = "语言"; Value = $(if ($St.Language -eq "en-US") { "英文" } else { "中文" }); Flag = $false; Guide = "选择界面语言。可随时按 L 在中文和英文之间切换。" }
        @{ Id = "start";   Kind = "start"; Label = "开始克隆";    Value = ""; Flag = $false; Guide = "按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。" }
    )
}

function Apply-GcrRecentToWizard {
    param($St, $Item)
    if ($null -eq $Item) { return }
    # Old history entries may lack any of these fields, and StrictMode makes a
    # bare property read on a missing key a terminating error, so read defensively.
    $u = $null; $d = $null; $rf = $null
    try { $u = [string]$Item.url } catch { }
    try { $d = [string]$Item.outDir } catch { }
    try { $rf = [string]$Item.ref } catch { }
    if ($u) { $St.Url = $u }
    if ($d) { $St.OutDir = $d; $St.OutDirAuto = $false }
    if ($rf) { $St.Ref = $rf }
    $St.Focus = "form"
    $St.Sel = 12
}

function Show-GcrTuiWizard {
    param([hashtable]$Defaults)
    if (-not (Test-GcrTuiActive)) {
        if (-not (Initialize-GcrTui)) { return $null }
    }
    $script:GcrTui.Screen = "wizard"
    $script:GcrTui.Phase = "wizard"
    $url = ""
    if ($Defaults -and $Defaults.ContainsKey("RepoUrl")) { $url = [string]$Defaults.RepoUrl }
    if (-not $url) {
        $clip = Get-GcrClipboardText
        if (Test-GcrRepoUrlText $clip) { $url = $clip }
    }
    $dir = ""
    $dirAuto = $true
    if ($Defaults -and $Defaults.ContainsKey("OutDir") -and $Defaults.OutDir) {
        $dir = [string]$Defaults.OutDir
        $dirAuto = $false
    }
    $ref = "HEAD"
    if ($Defaults -and $Defaults.ContainsKey("Ref") -and $Defaults.Ref) { $ref = [string]$Defaults.Ref }
    $batch = 32
    if ($Defaults -and $Defaults.ContainsKey("BatchSize") -and $Defaults.BatchSize) { $batch = [int]$Defaults.BatchSize }
    $retries = 8
    if ($Defaults -and $Defaults.ContainsKey("MaxRetries") -and $Defaults.MaxRetries) { $retries = [int]$Defaults.MaxRetries }
    $st = @{
        Url          = $url
        OutDir       = $dir
        OutDirAuto   = $dirAuto
        Ref          = $ref
        Language     = $(if ($script:GcrLanguage) { $script:GcrLanguage } else { "zh-CN" })
        BatchSize    = $batch
        MaxRetries   = $retries
        Include      = ""
        Exclude      = ""
        Depth        = ""
        Verify       = $false
        ForceRefetch = $false
        DryRun       = $false
        Sel          = 0
        RecentSel    = 0
        RecentTop    = 0
        Focus        = "form"
        Edit         = $false
        EditBuf      = ""
        EditCur      = 0
        EditField    = ""
        Recent       = @(Get-GcrHistory)
        Scroll       = 0
        ConfirmQuit     = $false
        ConfirmClearAll = $false
        ConfirmClearOne = $false
        Error           = ""
        Help            = $false
    }
    if ($Defaults -and $Defaults.ContainsKey("Verify")) { $st.Verify = [bool]$Defaults.Verify }
    if ($Defaults -and $Defaults.ContainsKey("ForceRefetch")) { $st.ForceRefetch = [bool]$Defaults.ForceRefetch }
    if ($Defaults -and $Defaults.ContainsKey("DryRun")) { $st.DryRun = [bool]$Defaults.DryRun }
    if ($Defaults -and $Defaults.ContainsKey("Include") -and $Defaults.Include) {
        $st.Include = (@($Defaults.Include) -join ",")
    }
    if ($Defaults -and $Defaults.ContainsKey("Exclude") -and $Defaults.Exclude) {
        $st.Exclude = (@($Defaults.Exclude) -join ",")
    }
    if ($Defaults -and $Defaults.ContainsKey("Depth") -and $Defaults.Depth) {
        $st.Depth = [string]$Defaults.Depth
    }

    # Reused for every input burst, so a key-repeat flood does not allocate.
    $batch = New-Object System.Collections.Generic.List[object]
    $dirty = $true

    # Click-to-select is only wired up while the wizard is on screen; mouse
    # reporting is switched off again the moment a clone starts, so click-drag
    # text selection works normally on the dashboard.
    [void](Enable-GcrMouse)

    while ($true) {
        if ($st.OutDirAuto -and $st.Url) {
            $st.OutDir = Get-GcrFolderNameSafe -Url $st.Url
        }
        $size = Get-GcrTuiSize
        if ($size.W -ne $script:GcrTui.Width -or $size.H -ne $script:GcrTui.Height) {
            $script:GcrTui.Width = $size.W
            $script:GcrTui.Height = $size.H
            $script:GcrTui.LastFrame = @()
            $dirty = $true
        }
        if ($dirty) {
            Render-GcrTuiWizard -St $st
            $dirty = $false
        }
        # Drain everything already queued and apply it as one batch, then paint
        # once. A held arrow key auto-repeats far faster than a PowerShell frame
        # can be composed; repainting per event made the queue outlive the
        # keypress, so the highlight kept moving after the user let go.
        $batch.Clear()
        [void](Receive-GcrTuiInputBatch -Sink $batch)
        if ($batch.Count -eq 0) {
            $ev = Read-GcrTuiInput -TimeoutMs 16
            if ($null -ne $ev) { [void]$batch.Add($ev) }
        }
        if ($batch.Count -eq 0) { continue }
        $dirty = $true

        $action = "continue"
        foreach ($ev in $batch) {
            if (Test-GcrMouseEvent $ev) {
                $action = Invoke-GcrWizardMouse -St $st -X ([int]$ev.X) -Y ([int]$ev.Y)
            } else {
                $action = Invoke-GcrWizardEvent -St $st -K $ev
            }
            if ($action -eq "start" -or $action -eq "close") { break }
        }
        if ($action -eq "close") {
            Disable-GcrMouse
            $script:GcrTui.Screen = "dash"
            return $null
        }
        if ($action -eq "start") {
            Disable-GcrMouse
            $wizResult = Convert-GcrWizardResult -St $st
            $script:GcrTui.Screen = "dash"
            $script:GcrTui.Logs.Clear()
            return ,$wizResult
        }
    }
    # Not normally reached (both exits above return), but leaving mouse reporting
    # on would break click-drag text selection for the rest of the session.
    Disable-GcrMouse
    return $null
}

# Applies one wizard input event to the wizard state and reports what the caller
# should do: "continue" to keep the wizard open, "close" to abandon it, or
# "start" to begin the clone. Extracted from the wizard loop so a whole burst of
# queued events can be applied in one pass before anything is painted.
function Invoke-GcrWizardEvent {
    param($St, $K)
    # Ladders for the numeric fields, used by the Left/RightArrow handling below.
    $batches = @(8, 16, 32, 64, 128, 256)
    $retriesSet = @(3, 5, 8, 12, 20)
    if ($st.ConfirmQuit) {
        if ($K.Key -eq "Enter" -or $K.Key -eq "Y" -or $K.Key -eq "Q") { return "close" }
        $st.ConfirmQuit = $false
        return "continue"
    }
    if ($st.ConfirmClearAll) {
        if ($K.Key -eq "Enter" -or $K.Key -eq "Y") {
            $n = Clear-GcrHistory
            $st.Recent = @()
            $st.RecentSel = 0
            $st.RecentTop = 0
            $st.Focus = "form"
            if ($n -gt 0) { $st.Error = "已清除全部历史记录。" }
            else { $st.Error = "没有可清除的历史记录。" }
        }
        $st.ConfirmClearAll = $false
        return "continue"
    }
    if ($st.ConfirmClearOne) {
        if ($K.Key -eq "Enter" -or $K.Key -eq "Y") {
            if ($st.Recent.Count -gt 0 -and $st.RecentSel -ge 0 -and $st.RecentSel -lt $st.Recent.Count) {
                $item = $st.Recent[$st.RecentSel]
                $urlDel = ""
                $dirDel = ""
                try { $urlDel = [string]$item.url } catch { }
                try { $dirDel = [string]$item.outDir } catch { }
                if (Remove-GcrHistoryEntry -Url $urlDel -OutDir $dirDel) {
                    $st.Recent = @(Get-GcrHistory)
                    if ($st.RecentSel -ge $st.Recent.Count) { $st.RecentSel = [Math]::Max(0, $st.Recent.Count - 1) }
                    if ($st.Recent.Count -eq 0) { $st.Focus = "form" }
                    $st.Error = "已删除该历史记录。"
                }
            }
        }
        $st.ConfirmClearOne = $false
        return "continue"
    }
    # Ctrl+S starts the clone from anywhere, including while a field is being
    # edited: it is the accelerator for the "开始克隆" row, so unlike a bare S it
    # works even when a text field has the caret. Checked before the switch and
    # before the edit branch, because Ctrl+S reports ConsoleKey S.
    if (Test-GcrCtrlKey $K "S") {
        if ([string]::IsNullOrWhiteSpace($st.Url) -or $st.Url -match "\s") {
            $st.Error = "请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）"
            $st.Sel = 0
            return "continue"
        }
        return "start"
    }

    if ($st.Edit) {
        $buf = [string]$st.EditBuf
        $cur = [int]$st.EditCur
        if ($cur -lt 0) { $cur = 0 }
        if ($cur -gt $buf.Length) { $cur = $buf.Length }
        if ($K.Key -eq "Escape") { $st.Edit = $false; return "continue" }
        if ($K.Key -eq "Enter") {
            $val = $buf
            switch ($st.EditField) {
                "url" { $st.Url = $val.Trim() }
                "dir" {
                    $st.OutDir = $val.Trim()
                    $st.OutDirAuto = [string]::IsNullOrWhiteSpace($st.OutDir)
                }
                "ref" { $st.Ref = $(if ($val.Trim()) { $val.Trim() } else { "HEAD" }) }
                "include" { $st.Include = $val.Trim() }
                "exclude" { $st.Exclude = $val.Trim() }
                "depth" { $st.Depth = $val.Trim() }
            }
            $st.Edit = $false
            return "continue"
        }
        if (Test-GcrCtrlKey $K "V") {
            $paste = Get-GcrClipboardText
            if ($paste) {
                $paste = ($paste -split "[\r\n]")[0]
                $buf = $buf.Substring(0, $cur) + $paste + $buf.Substring($cur)
                $cur = $cur + $paste.Length
            }
        } elseif ($K.Key -eq "LeftArrow") {
            if ($cur -gt 0) { $cur-- }
        } elseif ($K.Key -eq "RightArrow") {
            if ($cur -lt $buf.Length) { $cur++ }
        } elseif ($K.Key -eq "Home") { $cur = 0 }
        elseif ($K.Key -eq "End") { $cur = $buf.Length }
        elseif ($K.Key -eq "Backspace") {
            if ($cur -gt 0) { $buf = $buf.Remove($cur - 1, 1); $cur-- }
        } elseif ($K.Key -eq "Delete") {
            if ($cur -lt $buf.Length) { $buf = $buf.Remove($cur, 1) }
        } elseif (-not [string]::IsNullOrEmpty([string]$K.KeyChar) -and [int][char]$K.KeyChar -ge 32) {
            $buf = $buf.Insert($cur, [string]$K.KeyChar)
            $cur++
        }
        $st.EditBuf = $buf
        $st.EditCur = $cur
        return "continue"
    }

        if (Test-GcrCtrlKey $K "C") { $st.ConfirmQuit = $true; return "continue" }
    if (Test-GcrCtrlKey $K "D") {
        if ($st.Recent.Count -gt 0) { $st.ConfirmClearAll = $true }
        else { $st.Error = "没有可清除的历史记录。" }
        return "continue"
    }
    if (Test-GcrCtrlKey $K "V" -and $st.Focus -eq "form") {
        $paste = Get-GcrClipboardText
        if (Test-GcrRepoUrlText $paste) {
            $st.Url = $paste
            if ($st.OutDirAuto) { $st.OutDir = Get-GcrFolderNameSafe -Url $paste }
        }
        return "continue"
    }

    switch ($K.Key.ToString()) {
        "Q" { $st.ConfirmQuit = $true }
        "Escape" { $st.ConfirmQuit = $true }
        "Delete" {
            if ($st.Focus -eq "recent" -and $st.Recent.Count -gt 0) { $st.ConfirmClearOne = $true }
            elseif ($st.Recent.Count -gt 0) { $st.ConfirmClearAll = $true }
            else { $st.Error = "没有可清除的历史记录。" }
        }
        "Tab" {
            if ($st.Focus -eq "form") { $st.Focus = "recent"; if ($st.Recent.Count -eq 0) { $st.Focus = "form" } }
            else { $st.Focus = "form" }
        }
        "UpArrow" {
            if ($st.Focus -eq "recent") {
                if ($st.RecentSel -gt 0) {
                    $st.RecentSel--
                    if ($st.RecentSel -lt $st.RecentTop) { $st.RecentTop = $st.RecentSel }
                }
                else { $st.Focus = "form"; $st.Sel = 12 }
            } else {
                if ($st.Sel -gt 0) { $st.Sel-- }
            }
        }
        "DownArrow" {
            if ($st.Focus -eq "recent") {
                if ($st.RecentSel -lt ($st.Recent.Count - 1)) {
                    $st.RecentSel++
                    $recentVisible = [Math]::Max(1, [int](Get-GcrTuiSize).H - 10)
                    if ($st.RecentSel -ge $st.RecentTop + $recentVisible) {
                        $st.RecentTop = $st.RecentSel - $recentVisible + 1
                    }
                }
            } else {
                if ($st.Sel -lt 12) { $st.Sel++ }
                elseif ($st.Recent.Count -gt 0) {
                    $st.Focus = "recent"
                    $st.RecentSel = [Math]::Min($st.RecentSel, $st.Recent.Count - 1)
                    $recentVisible = [Math]::Max(1, [int](Get-GcrTuiSize).H - 10)
                    $st.RecentTop = [Math]::Max(0, $st.RecentSel - $recentVisible + 1)
                }
            }
        }
        "K" {
            if ($K.KeyChar -eq "k") {
                if ($st.Focus -eq "form" -and $st.Sel -gt 0) { $st.Sel-- }
            }
        }
        "J" {
            if ($K.KeyChar -eq "j") {
                if ($st.Focus -eq "form" -and $st.Sel -lt 12) { $st.Sel++ }
            }
        }
        "LeftArrow" {
            if ($st.Focus -eq "form" -and $st.Sel -eq 11) {
                $st.Language = "zh-CN"
            }
            if ($st.Focus -eq "form" -and $st.Sel -eq 3) {
                $idx = [array]::IndexOf($batches, [int]$st.BatchSize)
                if ($idx -lt 0) { $idx = 2 }
                if ($idx -gt 0) { $st.BatchSize = $batches[$idx - 1] }
            }
            if ($st.Focus -eq "form" -and $st.Sel -eq 4) {
                $idx = [array]::IndexOf($retriesSet, [int]$st.MaxRetries)
                if ($idx -lt 0) { $idx = 2 }
                if ($idx -gt 0) { $st.MaxRetries = $retriesSet[$idx - 1] }
            }
        }
        "RightArrow" {
            if ($st.Focus -eq "form" -and $st.Sel -eq 11) {
                $st.Language = "en-US"
            }
            if ($st.Focus -eq "form" -and $st.Sel -eq 3) {
                $idx = [array]::IndexOf($batches, [int]$st.BatchSize)
                if ($idx -lt 0) { $idx = 2 }
                if ($idx -lt $batches.Count - 1) { $st.BatchSize = $batches[$idx + 1] }
            }
            if ($st.Focus -eq "form" -and $st.Sel -eq 4) {
                $idx = [array]::IndexOf($retriesSet, [int]$st.MaxRetries)
                if ($idx -lt 0) { $idx = 2 }
                if ($idx -lt $retriesSet.Count - 1) { $st.MaxRetries = $retriesSet[$idx + 1] }
            }
        }
        "Spacebar" {
            if ($st.Focus -eq "form") {
                if ($st.Sel -eq 8) { $st.Verify = -not $st.Verify }
                elseif ($st.Sel -eq 9) { $st.ForceRefetch = -not $st.ForceRefetch }
                elseif ($st.Sel -eq 10) { $st.DryRun = -not $st.DryRun }
                elseif ($st.Sel -eq 11) { $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" }); Set-GcrLanguage -Language $st.Language }
            }
        }
        "Enter" {
            if ($st.Focus -eq "recent") {
                if ($st.Recent.Count -gt 0) { Apply-GcrRecentToWizard -St $st -Item $st.Recent[$st.RecentSel] }
                break
            }
            $wizItems = @(Get-GcrWizardItems -St $st)
            if ($st.Sel -lt 0 -or $st.Sel -ge $wizItems.Count) { break }
            $id = [string]$wizItems[$st.Sel].Id
            if ($id -eq "start") {
                if ([string]::IsNullOrWhiteSpace($st.Url) -or $st.Url -match "\s") {
                    $st.Error = "请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）"
                    $st.Sel = 0
                } else {
                    try {
                        $result = Convert-GcrWizardResult -St $st
                        $script:GcrTui.Screen = "dash"
                        $script:GcrTui.Logs.Clear()
                        return "start"
                    } catch {
                        $st.Error = "无法开始: " + $_.Exception.Message
                        $script:GcrTui.Screen = "wizard"
                    }
                }
            } elseif ($id -eq "verify") { $st.Verify = -not $st.Verify }
            elseif ($id -eq "force") { $st.ForceRefetch = -not $st.ForceRefetch }
            elseif ($id -eq "dry") { $st.DryRun = -not $st.DryRun }
            elseif ($id -eq "language") { $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" }); Set-GcrLanguage -Language $st.Language }
            elseif ($id -eq "batch" -or $id -eq "retry") { }
            else {
                $st.Edit = $true
                $st.EditField = $id
                $map = @{
                    url     = $st.Url
                    dir     = $st.OutDir
                    ref     = $st.Ref
                    include = $st.Include
                    exclude = $st.Exclude
                    depth   = $st.Depth
                }
                $st.EditBuf = [string]$map[$id]
                $st.EditCur = $st.EditBuf.Length
            }
        }
        "S" {
            if ([string]::IsNullOrWhiteSpace($st.Url)) {
                $st.Error = "请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）"
                $st.Sel = 0
            } else {
                # The caller builds the result; returning the action keeps one
                # start path instead of two.
                return "start"
            }
        }
        default {
            if ($K.KeyChar -eq "l" -or $K.KeyChar -eq "L") {
                $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" })
                Set-GcrLanguage -Language $st.Language
            }
            if ($K.KeyChar -eq "?") { $st.Error = "Enter 编辑 · Space 开关 · Tab 最近任务 · S 开始 · Q 退出" }
        }
    }
    if ($K.Key -ne "Enter" -and $K.Key -ne "Delete" -and -not (Test-GcrCtrlKey $K "D")) { $St.Error = "" }
    return "continue"
}

# Handles a left click anywhere on the wizard: a form row selects that item and
# acts on it (so clicking the start row starts, clicking a bool toggles, clicking
# a text field edits), and a recent-task row fills the form from it.
function Invoke-GcrWizardMouse {
    param($St, [int]$X, [int]$Y)
    if ($null -eq $script:GcrMouseHit) { return "continue" }
    if (-not $script:GcrMouseHit.ContainsKey($Y)) { return "continue" }

    # A click resolves a pending confirmation first: confirming is the safe
    # reading, and no row is actionable while the prompt is up.
    if ($St.ConfirmQuit) { return "close" }
    if ($St.ConfirmClearAll) { return Invoke-GcrWizardEvent -St $St -K (New-GcrSyntheticKey "Enter") }
    if ($St.ConfirmClearOne) { return Invoke-GcrWizardEvent -St $St -K (New-GcrSyntheticKey "Enter") }

    $hit = $script:GcrMouseHit[$Y]
    if ($hit.Kind -eq "recent") {
        $St.Focus = "recent"
        $St.RecentSel = [int]$hit.Index
        return Invoke-GcrWizardEvent -St $St -K (New-GcrSyntheticKey "Enter")
    }

    $index = [int]$hit.Index
    $St.Focus = "form"
    if ($St.Edit -and [int]$St.Sel -ne $index) {
        # Clicking away from a field being edited commits it first.
        $null = Invoke-GcrWizardEvent -St $St -K (New-GcrSyntheticKey "Enter")
    }
    if ($St.Edit) {
        # The click landed on the field already being edited; keep its caret.
        return "continue"
    }
    $St.Sel = $index
    return Invoke-GcrWizardEvent -St $St -K (New-GcrSyntheticKey "Enter")
}

# A key event the TUI generated itself, so a click can reuse the keyboard paths
# instead of duplicating "what Enter does" in two places.
function New-GcrSyntheticKey {
    param([string]$Key)
    return New-Object System.ConsoleKeyInfo([char]0, ([ConsoleKey]$Key), $false, $false, $false)
}
function Show-GcrCliWizard {
    param([hashtable]$Defaults)
    Write-Host ""
    Write-Host "git-clone-resume  交互设置" -ForegroundColor Cyan
    Write-Host "直接回车使用括号里的默认值。空 URL 则退出。" -ForegroundColor DarkGray
    Write-Host ""
    $pre = ""
    if ($Defaults -and $Defaults.ContainsKey("RepoUrl")) { $pre = [string]$Defaults.RepoUrl }
    if (-not $pre) {
        $clip = Get-GcrClipboardText
        if (Test-GcrRepoUrlText $clip) { $pre = $clip }
    }
    $prompt = "仓库 URL"
    if ($pre) { $prompt = "仓库 URL [$pre]" }
    $url = Read-Host (Convert-GcrText $prompt)
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $pre }
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    $defDir = Get-GcrFolderNameSafe -Url $url
    if ($Defaults -and $Defaults.ContainsKey("OutDir") -and $Defaults.OutDir) { $defDir = [string]$Defaults.OutDir }
    $dir = Read-Host (Convert-GcrText "本地目录 [$defDir]")
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $defDir }
    $defRef = "HEAD"
    if ($Defaults -and $Defaults.ContainsKey("Ref") -and $Defaults.Ref) { $defRef = [string]$Defaults.Ref }
    $ref = Read-Host (Convert-GcrText "分支/标签/commit [$defRef]")
    if ([string]::IsNullOrWhiteSpace($ref)) { $ref = $defRef }
    $batch = 32
    if ($Defaults -and $Defaults.ContainsKey("BatchSize") -and $Defaults.BatchSize) { $batch = [int]$Defaults.BatchSize }
    $batchText = Read-Host (Convert-GcrText "每批文件数 [$batch]")
    if ($batchText -match "^\d+$") { $batch = [int]$batchText }
    return @{
        RepoUrl      = $url.Trim()
        OutDir       = $dir
        Ref          = $ref
        BatchSize    = $batch
        MaxRetries   = 8
        Include      = @()
        Exclude      = @()
        Depth        = $null
        Verify       = $false
        ForceRefetch = $false
        DryRun       = $false
    }
}

function Show-GcrInteractiveSetup {
    param([hashtable]$Defaults)
    $raw = $null
    if (Test-GcrTuiAvailable) {
        if (Initialize-GcrTui) {
            $raw = Show-GcrTuiWizard -Defaults $Defaults
            return ,(ConvertFrom-GcrWizardOutput $raw)
        }
    }
    $raw = Show-GcrCliWizard -Defaults $Defaults
    return ,(ConvertFrom-GcrWizardOutput $raw)
}

function Write-GcrNewline {
    if (Test-GcrTuiActive) { return }
    Write-Host ""
    $script:GcrProgressOpen = $false
}
