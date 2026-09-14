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

function Get-GcrDisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $plain = [regex]::Replace($Text, [char]27 + '\[[0-9;?]*[ -/]*[@-~]', "")
    $w = 0
    foreach ($ch in $plain.ToCharArray()) { $w += Get-GcrCharWidth $ch }
    return $w
}

function Truncate-GcrDisplay {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return "" }
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ((Get-GcrDisplayWidth $Text) -le $Width) { return $Text }
    $ellipsis = "..."
    $budget = $Width - 3
    if ($budget -lt 1) { return Truncate-GcrDisplay -Text "." -Width $Width }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = Get-GcrCharWidth $ch
        if ($w + $cw -gt $budget) { break }
        [void]$sb.Append($ch)
        $w += $cw
    }
    return $sb.ToString() + $ellipsis
}

function Format-GcrCell {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return "" }
    $t = Truncate-GcrDisplay -Text ([string]$Text) -Width $Width
    $w = Get-GcrDisplayWidth $t
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
"@
    }
    return [GitCloneResume.Native]
}

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
    }
}

function Initialize-GcrTui {
    if (Test-GcrTuiActive) { return $true }
    if (-not (Test-GcrTuiAvailable)) { return $false }
    Initialize-GcrTuiState
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
    try { [Console]::Title = "git-clone-resume" } catch { }
    $script:GcrTui.Active = $true
    $script:GcrTui.Dirty = $true
    $script:GcrTui.LastFrame = @()
    return $true
}

function Close-GcrTui {
    if ($null -eq $script:GcrTui -or -not $script:GcrTui.Active) {
        $script:GcrTui = $null
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
    try {
        if ($script:GcrOrigTitle) { [Console]::Title = $script:GcrOrigTitle }
    } catch { }
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
    if (-not (Test-GcrTuiActive)) { return }
    if ($Name) { $script:GcrTui.Phase = $Name }
    if ($PSBoundParameters.ContainsKey("Detail")) { $script:GcrTui.PhaseDetail = $Detail }
    $script:GcrTui.Dirty = $true
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
        [string]$CurrentFile
    )
    if (-not (Test-GcrTuiActive)) { return }
    $script:GcrTui.Ok = $OkCount
    $script:GcrTui.Total = $TotalCount
    $script:GcrTui.Fail = $FailCount
    $script:GcrTui.Bytes = $DoneBytes
    $script:GcrTui.Rate = $Rate
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
    try {
        $short = Truncate-GcrDisplay -Text $script:GcrTui.RepoUrl -Width 40
        [Console]::Title = ("git-clone-resume {0}% {1}" -f $pct, $short)
    } catch { }
}

function Get-GcrHistoryPath {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [Environment]::GetFolderPath("ApplicationData") }
    return (Join-Path (Join-Path $root "git-clone-resume") "history.json")
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

function Read-GcrTuiKey {
    param([int]$TimeoutMs = 0)
    try {
        if ($TimeoutMs -le 0) {
            if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
            return $null
        }
        $end = [Environment]::TickCount + $TimeoutMs
        while ([Environment]::TickCount -lt $end) {
            if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
            Start-Sleep -Milliseconds 20
        }
    } catch { }
    return $null
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
        }
        "Escape" {
            if ($script:GcrTui.FailView) { $script:GcrTui.FailView = $false }
            else { $script:GcrTui.Paused = -not $script:GcrTui.Paused }
            $script:GcrTui.Dirty = $true
        }
        "Spacebar" {
            if ($script:GcrTui.Paused) { $script:GcrTui.Paused = $false }
            $script:GcrTui.Dirty = $true
        }
        "H" { $script:GcrTui.Help = $true; $script:GcrTui.Dirty = $true }
        "L" {
            $script:GcrLanguage = $(if ($script:GcrLanguage -eq "en-US") { "zh-CN" } else { "en-US" })
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
    $need = [bool]$Force -or [bool]$script:GcrTui.Dirty -or ($anim -and $ms -ge 250)
    if ($need -and $ms -ge 50) {
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
        Start-Sleep -Milliseconds 80
    }
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
    $c = @{
        R = Get-GcrColor "reset"
        B = Get-GcrColor "bold"
        D = Get-GcrColor "dim"
        C = Get-GcrColor "cyan"
        G = Get-GcrColor "green"
        Y = Get-GcrColor "yellow"
        E = Get-GcrColor "red"
        W = Get-GcrColor "white"
        T = Get-GcrColor "teal"
    }
    $box = $script:GcrTui.Box
    $lines = New-Object System.Collections.Generic.List[string]
    $inner = [Math]::Max(10, $w - 2)
    function Push-GcrBorder {
        param([string]$Kind)
        $ch = $box.H
        if ($Kind -eq "top") { $plain = $box.TL + ($ch * $inner) + $box.TR }
        elseif ($Kind -eq "bot") { $plain = $box.BL + ($ch * $inner) + $box.BR }
        else { $plain = $box.L + ($ch * $inner) + $box.R }
        [void]$lines.Add($c.D + (Format-GcrCell $plain $w) + $c.R)
    }
    function Push-GcrRow {
        param([string]$Left, [string]$Right = "", [string]$Color = "")
        if (-not $Color) { $Color = $c.W }
        $Left = Convert-GcrText $Left
        $Right = Convert-GcrText $Right
        $leftW = Get-GcrDisplayWidth $Left
        $rightW = Get-GcrDisplayWidth $Right
        $gap = $inner - $leftW - $rightW
        if ($gap -lt 1) {
            $keep = [Math]::Max(8, $inner - $rightW - 1)
            $Left = Truncate-GcrDisplay $Left $keep
            $leftW = Get-GcrDisplayWidth $Left
            $gap = $inner - $leftW - $rightW
            if ($gap -lt 0) { $Right = ""; $rightW = 0; $gap = $inner - $leftW }
            if ($gap -lt 0) { $gap = 0 }
        }
        $body = $Left + (" " * $gap) + $Right
        $plainSides = $box.V
        $row = $c.D + $plainSides + $c.R + $Color + $body + $c.R + $c.D + $plainSides + $c.R
        [void]$lines.Add($row)
    }

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
    $stats = (" {0}/{1}  失败 {2}  {3}  {4:N1}/s  ETA {5}" -f @(
            $script:GcrTui.Ok,
            $script:GcrTui.Total,
            $script:GcrTui.Fail,
            $bytes,
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
            foreach ($b in @($script:GcrTui.ResultBody)) {
                [void]$bodyLines.Add(@{ L = "INFO"; M = [string]$b; T = $null })
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
            Push-GcrRow -Left (" " + $text) -Color (Get-GcrLevelColor $lvl)
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
        $k = Read-GcrTuiKey -TimeoutMs 200
        if ($null -ne $k) {
            if ($k.Key -eq "Enter" -or $k.Key -eq "Q" -or $k.Key -eq "Escape" -or (Test-GcrCtrlKey $k "C")) {
                break
            }
            if ($k.KeyChar -eq "?") { $script:GcrTui.Help = -not $script:GcrTui.Help; Render-GcrTui }
        }
        $waited += 200
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

function Render-GcrTuiWizard {
    param($St)
    $size = Get-GcrTuiSize
    $w = $size.DrawW
    $h = $size.H
    $inner = [Math]::Max(10, $w - 2)
    $c = @{
        R = Get-GcrColor "reset"
        B = Get-GcrColor "bold"
        D = Get-GcrColor "dim"
        C = Get-GcrColor "cyan"
        G = Get-GcrColor "green"
        Y = Get-GcrColor "yellow"
        E = Get-GcrColor "red"
        W = Get-GcrColor "white"
    }
    $box = $script:GcrTui.Box
    $lines = New-Object System.Collections.Generic.List[string]
    function WBorder([string]$Kind) {
        $ch = $box.H
        if ($Kind -eq "top") { $plain = $box.TL + ($ch * $inner) + $box.TR }
        elseif ($Kind -eq "bot") { $plain = $box.BL + ($ch * $inner) + $box.BR }
        else { $plain = $box.L + ($ch * $inner) + $box.R }
        [void]$lines.Add($c.D + (Format-GcrCell $plain $w) + $c.R)
    }
    function WRow([string]$Text, [string]$Color, [switch]$Sel) {
        if (-not $Color) { $Color = $c.W }
        $Text = Convert-GcrText $Text
        $body = Format-GcrCell -Text $Text -Width $inner
        if ($Sel) { $Color = (Get-GcrColor "rev") + $Color }
        $row = $c.D + $box.V + $c.R + $Color + $body + $c.R + $c.D + $box.V + $c.R
        [void]$lines.Add($row)
    }

    $items = Get-GcrWizardItems -St $St
    WBorder "top"
    WRow " git-clone-resume" ($c.B + $c.C)
    WRow " 断点续传克隆  ·  partial clone + 按批 checkout" $c.D
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
        $label = Format-GcrCell $it.Label 20
        $text = $mark + " " + $label + " " + $val
        $col = $c.W
        if ($it.Kind -eq "start") { $col = $c.G + $c.B }
        WRow $text $col -Sel:($sel -eq $i -and -not $St.Edit)
    }

    WBorder "mid"
    WRow " 最近任务  (Tab 切换  ·  Enter 填入)" $c.D
    $recentSlots = $h - $lines.Count - 4
    if ($recentSlots -lt 1) { $recentSlots = 1 }
    if ($recent.Count -eq 0) {
        WRow "    （无。完成一次克隆后会出现在这里）" $c.D
        $recentSlots--
    } else {
        $show = [Math]::Min($recent.Count, [Math]::Max(1, $recentSlots))
        for ($r = 0; $r -lt $show; $r++) {
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
            WRow $text $(if ($isSel) { $c.C } else { $c.D }) -Sel:$isSel
            $recentSlots--
        }
    }
    while ($recentSlots -gt 0) { WRow "" $c.D; $recentSlots-- }

    WBorder "mid"
    $guide = Get-GcrWizardGuide -St $St
    if ($St.Error) { $guide = [string]$St.Error }
    $guideColor = $c.C
    if ($St.Error) { $guideColor = $c.E }
    if ($St.ConfirmQuit) { $guideColor = $c.Y }
    WRow (" " + $guide) $guideColor
    $foot = " Enter 编辑/开始  ·  Space 开关  ·  ←→ 改批次  ·  Ctrl+V 粘贴  ·  Q 退出"
    if ($St.Edit) { $foot = " Enter 确认  ·  Esc 取消  ·  Ctrl+V 粘贴" }
    if ($St.ConfirmQuit) { $foot = " Enter 确定退出  ·  Esc 返回" }
    WRow $foot $c.D
    WBorder "bot"
    while ($lines.Count -gt $h) { $lines.RemoveAt($lines.Count - 1) }
    while ($lines.Count -lt $h) { [void]$lines.Add("") }
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
    if ($Item.url) { $St.Url = [string]$Item.url }
    if ($Item.outDir) { $St.OutDir = [string]$Item.outDir; $St.OutDirAuto = $false }
    if ($Item.ref) { $St.Ref = [string]$Item.ref }
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
        Focus        = "form"
        Edit         = $false
        EditBuf      = ""
        EditCur      = 0
        EditField    = ""
        Recent       = @(Get-GcrHistory)
        Scroll       = 0
        ConfirmQuit  = $false
        Error        = ""
        Help         = $false
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

    $batches = @(8, 16, 32, 64, 128, 256)
    $retriesSet = @(3, 5, 8, 12, 20)
    $dirty = $true

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
        $k = Read-GcrTuiKey -TimeoutMs 250
        if ($null -eq $k) { continue }
        $dirty = $true

        if ($st.ConfirmQuit) {
            if ($k.Key -eq "Enter" -or $k.Key -eq "Y" -or $k.Key -eq "Q") { return $null }
            $st.ConfirmQuit = $false
            continue
        }
        if ($st.Edit) {
            $buf = [string]$st.EditBuf
            $cur = [int]$st.EditCur
            if ($cur -lt 0) { $cur = 0 }
            if ($cur -gt $buf.Length) { $cur = $buf.Length }
            if ($k.Key -eq "Escape") { $st.Edit = $false; continue }
            if ($k.Key -eq "Enter") {
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
                continue
            }
            if (Test-GcrCtrlKey $k "V") {
                $paste = Get-GcrClipboardText
                if ($paste) {
                    $paste = ($paste -split "[\r\n]")[0]
                    $buf = $buf.Substring(0, $cur) + $paste + $buf.Substring($cur)
                    $cur = $cur + $paste.Length
                }
            } elseif ($k.Key -eq "LeftArrow") {
                if ($cur -gt 0) { $cur-- }
            } elseif ($k.Key -eq "RightArrow") {
                if ($cur -lt $buf.Length) { $cur++ }
            } elseif ($k.Key -eq "Home") { $cur = 0 }
            elseif ($k.Key -eq "End") { $cur = $buf.Length }
            elseif ($k.Key -eq "Backspace") {
                if ($cur -gt 0) { $buf = $buf.Remove($cur - 1, 1); $cur-- }
            } elseif ($k.Key -eq "Delete") {
                if ($cur -lt $buf.Length) { $buf = $buf.Remove($cur, 1) }
            } elseif (-not [string]::IsNullOrEmpty([string]$k.KeyChar) -and [int][char]$k.KeyChar -ge 32) {
                $buf = $buf.Insert($cur, [string]$k.KeyChar)
                $cur++
            }
            $st.EditBuf = $buf
            $st.EditCur = $cur
            continue
        }

        if (Test-GcrCtrlKey $k "C") { $st.ConfirmQuit = $true; continue }
        if (Test-GcrCtrlKey $k "V" -and $st.Focus -eq "form") {
            $paste = Get-GcrClipboardText
            if (Test-GcrRepoUrlText $paste) {
                $st.Url = $paste
                if ($st.OutDirAuto) { $st.OutDir = Get-GcrFolderNameSafe -Url $paste }
            }
            continue
        }

        switch ($k.Key.ToString()) {
            "Q" { $st.ConfirmQuit = $true }
            "Escape" { $st.ConfirmQuit = $true }
            "Tab" {
                if ($st.Focus -eq "form") { $st.Focus = "recent"; if ($st.Recent.Count -eq 0) { $st.Focus = "form" } }
                else { $st.Focus = "form" }
            }
            "UpArrow" {
                if ($st.Focus -eq "recent") {
                    if ($st.RecentSel -gt 0) { $st.RecentSel-- }
                    else { $st.Focus = "form"; $st.Sel = 12 }
                } else {
                    if ($st.Sel -gt 0) { $st.Sel-- }
                }
            }
            "DownArrow" {
                if ($st.Focus -eq "recent") {
                    if ($st.RecentSel -lt ($st.Recent.Count - 1)) { $st.RecentSel++ }
                } else {
                    if ($st.Sel -lt 12) { $st.Sel++ }
                    elseif ($st.Recent.Count -gt 0) { $st.Focus = "recent"; $st.RecentSel = 0 }
                }
            }
            "K" {
                if ($k.KeyChar -eq "k") {
                    if ($st.Focus -eq "form" -and $st.Sel -gt 0) { $st.Sel-- }
                }
            }
            "J" {
                if ($k.KeyChar -eq "j") {
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
                    elseif ($st.Sel -eq 11) { $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" }); $script:GcrLanguage = $st.Language }
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
                            return ,$result
                        } catch {
                            $st.Error = "无法开始: " + $_.Exception.Message
                            $script:GcrTui.Screen = "wizard"
                        }
                    }
                } elseif ($id -eq "verify") { $st.Verify = -not $st.Verify }
                elseif ($id -eq "force") { $st.ForceRefetch = -not $st.ForceRefetch }
                elseif ($id -eq "dry") { $st.DryRun = -not $st.DryRun }
                elseif ($id -eq "language") { $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" }); $script:GcrLanguage = $st.Language }
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
                if (-not [string]::IsNullOrWhiteSpace($st.Url)) {
                    try {
                        $result = Convert-GcrWizardResult -St $st
                        $script:GcrTui.Screen = "dash"
                        $script:GcrTui.Logs.Clear()
                        return ,$result
                    } catch {
                        $st.Error = "无法开始: " + $_.Exception.Message
                        $script:GcrTui.Screen = "wizard"
                    }
                }
            }
            default {
                if ($k.KeyChar -eq "l" -or $k.KeyChar -eq "L") {
                    $st.Language = $(if ($st.Language -eq "en-US") { "zh-CN" } else { "en-US" })
                    $script:GcrLanguage = $st.Language
                }
                if ($k.KeyChar -eq "?") { $st.Error = "Enter 编辑 · Space 开关 · Tab 最近任务 · S 开始 · Q 退出" }
            }
        }
        if ($k.Key -ne "Enter") { $st.Error = "" }
    }
    return $null
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
}
