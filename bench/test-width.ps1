# Differential test: the rewritten width/truncate/format helpers in
# git-clone-resume.tui.ps1 must produce output equivalent to the versions they
# replaced (bench\legacy\width-reference.ps1, frozen from git HEAD).
#
# One deliberate difference: Format-GcrCell now strips ANSI sequences before
# measuring, where the old implementation kept them in the result. Keeping them
# meant padding was computed against the stripped width but applied to the styled
# string, so the extra escape bytes overran the cell. No production caller passes
# styled text here (all three call sites pass plain text built by the renderer),
# so the new behaviour is both safer and unobservable; the comparison below
# normalises ANSI away to assert the *visible* result is unchanged.
#
# Run:  powershell -NoProfile -File bench\test-width.ps1
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "load-gcr.ps1")

$esc = [char]27

# --- Current implementation, evaluated in an isolated module -----------------
# A module has its own session state, so the `$script:` values the helpers close
# over belong to this module. That matters when the suite is started from a
# parent script that already evaluated the same function block (test-all.ps1):
# dot-sourcing it again into a child scope leaves the inherited function objects
# bound to the parent's `$script:` scope, where GcrEsc/GcrAnsiRegex are unset, so
# the ANSI cases would silently compare against the wrong thing.
$current = Get-Module -Name GcrCurrent -ErrorAction SilentlyContinue
if ($current) { Remove-Module GcrCurrent -Force }
New-Module -Name GcrCurrent -ScriptBlock {
    param($Block, $Esc)
    $script:GcrWidthTable = $null
    $script:GcrEsc = $Esc
    $script:GcrAnsiRegex = $Esc + '\[[0-9;?]*[ -/]*[@-~]'
    . $Block
    [void](Get-GcrWidthTable)

    # Self-check: the code under test must see an ESC byte, otherwise an ANSI
    # mismatch looks like a formatting bug when it is really a harness bug.
    $probe = "$Esc[92mprobe$Esc[0m"
    if ($script:GcrEsc -ne [char]27 -or $probe.IndexOf($script:GcrEsc) -ne 0) {
        throw "harness error: the code under test cannot see ESC"
    }

    Export-ModuleMember -Function Get-GcrDisplayWidth, Truncate-GcrDisplay, Format-GcrCell, Get-GcrCharWidth
} -ArgumentList @((Get-GcrFunctionBlock -Paths @((Join-Path $root "git-clone-resume.tui.ps1"))).Block, $esc) |
    Import-Module -Force

# --- Reference implementation, in its own module so names do not clash -------
$legacy = Get-Module -Name GcrLegacy -ErrorAction SilentlyContinue
if ($legacy) { Remove-Module GcrLegacy -Force }
New-Module -Name GcrLegacy -ScriptBlock {
    param($Block, $Esc)
    $script:GcrWidthTable = $null
    $script:GcrAnsiRegex = $Esc + '\[[0-9;?]*[ -/]*[@-~]'
    . $Block
    Export-ModuleMember -Function Get-GcrDisplayWidth, Truncate-GcrDisplay, Format-GcrCell, Get-GcrCharWidth
} -ArgumentList @((Get-GcrFunctionBlock -Paths @((Join-Path $PSScriptRoot "legacy\width-reference.ps1"))).Block, $esc) |
    Import-Module -Force

# Module-qualified calls only: an unqualified call would be served by whatever
# the caller's scope happens to have defined.
function Get-NewWidth { param([string]$Text) GcrCurrent\Get-GcrDisplayWidth -Text $Text }
function Get-NewTrunc { param([string]$Text, [int]$Width) GcrCurrent\Truncate-GcrDisplay -Text $Text -Width $Width }
function Get-NewCell { param([string]$Text, [int]$Width) GcrCurrent\Format-GcrCell -Text $Text -Width $Width }
function Get-OldWidth { param([string]$Text) GcrLegacy\Get-GcrDisplayWidth -Text $Text }
function Get-OldTrunc { param([string]$Text, [int]$Width) GcrLegacy\Truncate-GcrDisplay -Text $Text -Width $Width }
function Get-OldCell { param([string]$Text, [int]$Width) GcrLegacy\Format-GcrCell -Text $Text -Width $Width }

# Visible text only: Format-GcrCell intentionally drops escape sequences now, so
# the cells are compared on what the user would actually see.
$ansiRe = $esc + '\[[0-9;?]*[ -/]*[@-~]'
function Get-Visible { param([string]$Text) [regex]::Replace($Text, $ansiRe, "") }

# --- Cases covering the widths, the boundaries and the styled input ----------
$cases = @(
    @{ Name = "empty"; Text = ""; Width = 20 }
    @{ Name = "single space"; Text = " "; Width = 5 }
    @{ Name = "ascii exact fit"; Text = "abcde"; Width = 5 }
    @{ Name = "ascii one short"; Text = "abcd"; Width = 5 }
    @{ Name = "ascii overflow"; Text = "abcdefghij"; Width = 5 }
    @{ Name = "ascii wide overflow"; Text = ("x" * 120); Width = 40 }
    @{ Name = "path"; Text = "src/core/module-042/impl.ps1"; Width = 30 }
    @{ Name = "cjk exact"; Text = "中文测试"; Width = 8 }
    @{ Name = "cjk odd width"; Text = "中文测试"; Width = 7 }
    @{ Name = "cjk overflow"; Text = "中文测试文件路径"; Width = 9 }
    @{ Name = "cjk narrow"; Text = "中文"; Width = 3 }
    @{ Name = "mixed"; Text = " 12:34:56 checkout ok  src/core/中文文件-0042.ps1"; Width = 44 }
    @{ Name = "mixed tight"; Text = " 12:34:56 checkout ok  src/core/中文文件-0042.ps1"; Width = 20 }
    @{ Name = "fullwidth forms"; Text = [string][char]0xFF21 + [string][char]0xFF22 + "AB"; Width = 5 }
    @{ Name = "hangul"; Text = "한국어테스트"; Width = 10 }
    @{ Name = "kana"; Text = "テストです"; Width = 8 }
    @{ Name = "wide punctuation"; Text = "a" + [string][char]0x3002 + "b"; Width = 4 }
    @{ Name = "ansi styled"; Text = "$esc[92mgreen text$esc[0m"; Width = 20 }
    @{ Name = "ansi only"; Text = "$esc[0m"; Width = 10 }
    @{ Name = "box drawing"; Text = ([string][char]0x2500 * 10); Width = 6 }
    @{ Name = "block bar"; Text = ([string][char]0x2588 * 8) + ([string][char]0x2591 * 8); Width = 10 }
    @{ Name = "arrow glyphs"; Text = " Q 停止 · P 暂停 · ? 帮助"; Width = 22 }
    @{ Name = "width zero"; Text = "abc"; Width = 0 }
    @{ Name = "width one"; Text = "abc"; Width = 1 }
    @{ Name = "width two"; Text = "abc"; Width = 2 }
    @{ Name = "width three"; Text = "abcdef"; Width = 3 }
    @{ Name = "width four"; Text = "abcdef"; Width = 4 }
    @{ Name = "tabs"; Text = "a`tb`tc"; Width = 10 }
    @{ Name = "combining"; Text = "e" + [string][char]0x0301 + "x"; Width = 4 }
    @{ Name = "cedilla"; Text = [string][char]0x00E9 + "clair"; Width = 8 }
)

$fail = 0
$checked = 0
$rows = New-Object System.Collections.Generic.List[object]

foreach ($case in $cases) {
    $t = [string]$case.Text
    $w = [int]$case.Width

    $newWidth = Get-NewWidth -Text $t
    $oldWidth = Get-OldWidth -Text $t
    $wOk = ($newWidth -eq $oldWidth)

    $newTrunc = Get-NewTrunc -Text $t -Width $w
    $oldTrunc = Get-OldTrunc -Text $t -Width $w
    $tOk = ((Get-Visible $newTrunc) -ceq (Get-Visible $oldTrunc))

    $newCell = Get-NewCell -Text $t -Width $w
    $oldCell = Get-OldCell -Text $t -Width $w
    $cOk = ((Get-Visible $newCell) -ceq (Get-Visible $oldCell))

    $checked++
    if (-not ($wOk -and $tOk -and $cOk)) { $fail++ }

    [void]$rows.Add([pscustomobject]@{
            Case    = $case.Name
            W       = $w
            Width   = if ($wOk) { "ok" } else { "MISMATCH ($oldWidth -> $newWidth)" }
            Trunc   = if ($tOk) { "ok" } else { "MISMATCH" }
            Cell    = if ($cOk) { "ok" } else { "MISMATCH" }
        })

    if (-not $tOk) { Write-Host ("  truncate {0}: old=[{1}] new=[{2}]" -f $case.Name, $oldTrunc, $newTrunc) }
    if (-not $cOk) { Write-Host ("  cell     {0}: old=[{1}] new=[{2}]" -f $case.Name, $oldCell, $newCell); Write-Host ("    new hex: " + (($newCell.ToCharArray() | ForEach-Object { "{0:X2}" -f [int]$_ }) -join " ")) }
}

# --- Also verify Get-GcrCharWidth still agrees with the table ----------------
$charFail = 0
foreach ($code in @(0, 9, 32, 65, 126, 127, 0x00E9, 0x1100, 0x115F, 0x2329, 0x2500, 0x2588, 0x2591,
        0x3002, 0x303F, 0x3042, 0x4E2D, 0xA4CF, 0xAC00, 0xD7A3, 0xF900, 0xFAFF,
        0xFE10, 0xFE30, 0xFF21, 0xFF60, 0xFFE0, 0xFFE6, 0xFFFD)) {
    $ch = [char]$code
    $new = GcrCurrent\Get-GcrCharWidth -Ch $ch
    $old = GcrLegacy\Get-GcrCharWidth -Ch $ch
    if ($new -ne $old) {
        Write-Host ("  charWidth U+{0:X4}: old={1} new={2}" -f $code, $old, $new)
        $charFail++
    }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host

Write-Host ("width/truncate/format cases: {0} checked, {1} mismatched" -f $checked, $fail)
Write-Host ("char-width probes:           {0} mismatched" -f $charFail)

if ($fail -gt 0 -or $charFail -gt 0) {
    Write-Host "FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All differential checks passed." -ForegroundColor Green
