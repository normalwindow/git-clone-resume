# Verifies the keyboard input path against a REAL console.
#
# The agent shell has no console, so the interactive path cannot be exercised
# directly. This attaches to the parent cmd.exe console (which exists even when
# stdio is piped) and then checks that [Console]::KeyAvailable / ReadKey behave
# under the exact console modes Enable-GcrVt sets - that is the combination that
# must keep working for keyboard input not to be lost.
#
#   powershell -NoProfile -File bench\check-keyboard-console.ps1
$ErrorActionPreference = "Continue"
$out = New-Object System.Collections.Generic.List[string]
function Say { param([string]$T) [void]$out.Add($T); Write-Host $T }

Add-Type -Namespace GcrKb -Name Con -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool AttachConsole(uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr h, uint m);
"@

Say "=== attach to the parent console ==="
$attached = $false
try {
    # -1 = ATTACH_PARENT_PROCESS
    $attached = [GcrKb.Con]::AttachConsole([uint32]::MaxValue)
} catch { }
Say ("  AttachConsole => {0}" -f $attached)
if (-not $attached) {
    Say "  no parent console available; cannot verify here."
    $out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "keyboard-console-results.txt") -Encoding UTF8
    exit 0
}

try {
    $hIn = [GcrKb.Con]::GetStdHandle(-10)
    $mode0 = [uint32]0
    $ok = [GcrKb.Con]::GetConsoleMode($hIn, [ref]$mode0)
    Say ("  GetConsoleMode(stdin) = {0}  mode = 0x{1:X}" -f $ok, $mode0)
    if (-not $ok) {
        Say "  stdin is not a console handle; cannot verify."
        $out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "keyboard-console-results.txt") -Encoding UTF8
        exit 0
    }

    # Exactly what Enable-GcrVt does to the input mode.
    $extended = [uint32]0x0080
    $quickEdit = [uint32]0x0040
    $tuiMode = ($mode0 -bor $extended) -band (-bnot $quickEdit)
    [void][GcrKb.Con]::SetConsoleMode($hIn, $tuiMode)
    $m1 = [uint32]0
    [void][GcrKb.Con]::GetConsoleMode($hIn, [ref]$m1)
    Say ("  TUI input mode set: 0x{0:X} (quick-edit cleared: {1})" -f $m1, (($m1 -band 0x0040) -eq 0))

    Say ""
    Say "=== keyboard path under TUI mode ==="
    Say ("  [Console]::KeyAvailable  => {0}" -f ([Console]::KeyAvailable))
    Say ("  [Console]::TreatControlCAsInput => {0}" -f ([Console]::TreatControlCAsInput))
    try {
        [Console]::TreatControlCAsInput = $true
        Say ("  set TreatControlCAsInput=true => {0}" -f ([Console]::TreatControlCAsInput))
    } catch {
        Say ("  FAIL setting TreatControlCAsInput: {0}" -f $_.Exception.Message)
    }

    # ReadKey must not throw when nothing is pending.
    try {
        if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); Say ("  unexpected key: {0}" -f $k.Key) }
        else { Say "  OK   ReadKey not called (nothing pending), KeyAvailable usable" }
    } catch {
        Say ("  FAIL KeyAvailable/ReadKey threw: {0}" -f $_.Exception.Message)
    }

    # Now with mouse reporting on top, which is the mode the wizard uses.
    Say ""
    Say "=== keyboard path with mouse reporting on ==="
    $mouseInput = [uint32]0x0010
    [void][GcrKb.Con]::SetConsoleMode($hIn, [uint32](($m1 -bor $mouseInput) -band (-bnot $quickEdit)))
    $m2 = [uint32]0
    [void][GcrKb.Con]::GetConsoleMode($hIn, [ref]$m2)
    Say ("  input mode now: 0x{0:X} (mouse bit: {1})" -f $m2, (($m2 -band 0x0010) -ne 0))
    try {
        Say ("  KeyAvailable => {0}" -f ([Console]::KeyAvailable))
        Say "  OK   KeyAvailable still usable with mouse reporting on"
    } catch {
        Say ("  FAIL KeyAvailable threw with mouse on: {0}" -f $_.Exception.Message)
    }

    # Restore.
    [void][GcrKb.Con]::SetConsoleMode($hIn, $mode0)
    Say ""
    Say "  restored original input mode."
} finally {
    [void][GcrKb.Con]::FreeConsole()
}

$out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "keyboard-console-results.txt") -Encoding UTF8
