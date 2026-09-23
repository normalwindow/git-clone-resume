# Runtime check of the console input P/Invoke layer.
#
# The unit tests load functions via the AST and never execute Add-Type, so a
# compile or marshalling failure in the native layer would not show up there.
# This runs the real functions.
#
#   powershell -NoProfile -File bench\check-native-input.ps1
$ErrorActionPreference = "Continue"
$out = New-Object System.Collections.Generic.List[string]
function Say { param([string]$T) [void]$out.Add($T) }

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Initialize-GcrTuiState

Say "=== Get-GcrNativeType (Add-Type compile) ==="
try {
    $t = Get-GcrNativeType
    Say ("  OK   type = {0}" -f $t.FullName)
} catch {
    Say ("  FAIL Add-Type threw: {0}" -f $_.Exception.Message)
    if ($_.Exception.InnerException) { Say ("       inner: {0}" -f $_.Exception.InnerException.Message) }
    $out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "native-input-results.txt") -Encoding UTF8
    $out | ForEach-Object { Write-Host $_ }
    exit 1
}

Say ""
Say "=== struct layout ==="
# Static [type] references, not reflection: GetNestedType plus SizeOf(object)
# cannot be resolved in a constrained language mode, and the point here is to
# check the marshalled layout, which the type literals give directly.
$layoutOk = $true
function Test-GcrSize {
    param([string]$What, $Size, [int]$Want)
    $ok = ($Size -eq $Want)
    if (-not $ok) { $script:layoutOk = $false }
    Say ("  {0} {1} = {2} (want {3})" -f $(if ($ok) { "OK  " } else { "FAIL" }), $What, $Size, $Want)
}
Test-GcrSize "KEY_EVENT_RECORD" ([System.Runtime.InteropServices.Marshal]::SizeOf([type][GitCloneResume.Native+KEY_EVENT_RECORD])) 16
Test-GcrSize "MOUSE_EVENT_RECORD" ([System.Runtime.InteropServices.Marshal]::SizeOf([type][GitCloneResume.Native+MOUSE_EVENT_RECORD])) 16
Test-GcrSize "INPUT_RECORD" ([System.Runtime.InteropServices.Marshal]::SizeOf([type][GitCloneResume.Native+INPUT_RECORD])) 20

Say ""
Say "=== field offsets (must match Win32) ==="
$kTy = [type][GitCloneResume.Native+KEY_EVENT_RECORD]
foreach ($f in @(
        @("bKeyDown", 0), @("wRepeatCount", 4), @("wVirtualKeyCode", 6),
        @("wVirtualScanCode", 8), @("UnicodeChar", 10), @("dwControlKeyState", 12))) {
    $off = [System.Runtime.InteropServices.Marshal]::OffsetOf($kTy, $f[0])
    $ok = ($off -eq $f[1])
    if (-not $ok) { $layoutOk = $false }
    Say ("  {0} {1,-18} offset {2,3} (want {3,3})" -f $(if ($ok) { "OK  " } else { "FAIL" }), $f[0], $off, $f[1])
}
$mTy = [type][GitCloneResume.Native+MOUSE_EVENT_RECORD]
foreach ($f in @(@("dwMousePositionX", 0), @("dwMousePositionY", 2), @("dwButtonState", 4),
        @("dwControlKeyState", 8), @("dwEventFlags", 12))) {
    $off = [System.Runtime.InteropServices.Marshal]::OffsetOf($mTy, $f[0])
    $ok = ($off -eq $f[1])
    if (-not $ok) { $layoutOk = $false }
    Say ("  {0} {1,-18} offset {2,3} (want {3,3})" -f $(if ($ok) { "OK  " } else { "FAIL" }), $f[0], $off, $f[1])
}

Say ""
Say "=== console handles / modes ==="
$hIn = $t::GetStdHandle(-10)
$hOut = $t::GetStdHandle(-11)
Say ("  stdin  handle = {0}" -f $hIn)
Say ("  stdout handle = {0}" -f $hOut)
$inMode = [uint32]0
$inOk = $t::GetConsoleMode($hIn, [ref]$inMode)
Say ("  GetConsoleMode(stdin) = {0}  mode = 0x{1:X}" -f $inOk, $inMode)

if (-not $inOk) {
    Say "  (no console attached here - cannot exercise reads; that is expected in a pipe/agent shell)"
} else {
    Say ""
    Say "=== ReadConsoleInput on an empty queue ==="
    try {
        $buf = New-Object 'GitCloneResume.Native+INPUT_RECORD[]' 64
        $n = [uint32]0
        $ok = $t::ReadConsoleInput($hIn, $buf, [uint32]64, [ref]$n)
        Say ("  ReadConsoleInput returned {0}, events = {1}" -f $ok, $n)
        Say ("  buffer type = {0}, length = {1}" -f $buf.GetType().FullName, $buf.Length)
    } catch {
        Say ("  FAIL ReadConsoleInput threw: {0}" -f $_.Exception.Message)
    }
}

Say ""
Say "=== Enable-GcrMouse / Disable-GcrMouse ==="
# Simulation needs the native layer to believe it is active; in a piped shell
# there is no console mode to read, so this exercises the guard paths only.
$script:GcrNativeReady = $true
$mouse = Enable-GcrMouse
Say ("  Enable-GcrMouse => {0} (false is correct without a console)" -f $mouse)
if ($inOk) {
    $m2 = [uint32]0
    [void]$t::GetConsoleMode($hIn, [ref]$m2)
    Say ("  mouse bit set after enable: {0}" -f (($m2 -band 0x0010) -ne 0))
    Disable-GcrMouse
    $m3 = [uint32]0
    [void]$t::GetConsoleMode($hIn, [ref]$m3)
    Say ("  mouse bit set after disable: {0}" -f (($m3 -band 0x0010) -ne 0))
}

Say ""
Say "=== input layer must never throw, and must not lose keys ==="
# The keyboard path must work with no console and no mouse: that combination is
# exactly what broke when keys were routed through ReadConsoleInput.
try {
    $script:GcrMouseReady = $false
    $script:GcrPendingInput.Clear()
    Receive-GcrTuiInput
    Say ("  OK   Receive-GcrTuiInput key-path did not throw (queued {0})" -f $script:GcrPendingInput.Count)
} catch {
    Say ("  FAIL Receive-GcrTuiInput threw: {0}" -f $_.Exception.Message)
}
try {
    $script:GcrPendingInput.Clear()
    $k = Read-GcrTuiKey -TimeoutMs 0
    Say ("  OK   Read-GcrTuiKey returned {0}" -f $(if ($null -eq $k) { "null" } else { $k.Key }))
} catch {
    Say ("  FAIL Read-GcrTuiKey threw: {0}" -f $_.Exception.Message)
}

# A queued key must survive the mouse-enabled path: the native reader must not
# run while a key is pending, or the key could be consumed by the wrong reader.
try {
    $script:GcrPendingInput.Clear()
    [void]$script:GcrPendingInput.Add((New-Object System.ConsoleKeyInfo([char]0, [ConsoleKey]::DownArrow, $false, $false, $false)))
    $script:GcrMouseReady = $true          # pretend clicks are on
    $script:GcrInputBuf = $null            # ... but the buffer is missing
    Receive-GcrTuiInput
    $stillThere = ($script:GcrPendingInput.Count -eq 1)
    Say ("  {0} queued key untouched by the mouse reader: {1}" -f $(if ($stillThere) { "OK  " } else { "FAIL" }), $script:GcrPendingInput.Count)
    $k2 = Read-GcrTuiKey -TimeoutMs 0
    Say ("  {0} Read-GcrTuiKey returned {1}" -f $(if ($null -ne $k2 -and $k2.Key -eq [ConsoleKey]::DownArrow) { "OK  " } else { "FAIL" }), $(if ($null -eq $k2) { "null" } else { $k2.Key }))
    $script:GcrMouseReady = $false
} catch {
    Say ("  FAIL queued-key check threw: {0}" -f $_.Exception.Message)
}

# The mouse reader must be allowed to fail without taking the keyboard with it.
# ReadConsoleInput hands back key records as well, and anything it removes is gone
# from the buffer, so a key record has to be treated as a fault that retires mouse
# support rather than something to quietly discard.
Say ""
Say "=== a mouse-reader fault must not cost keyboard input ==="
try {
    $script:GcrMouseHit = $null
    $script:GcrMouseReady = $true
    $script:GcrMouseFaults = 0
    $script:GcrInputBuf = New-Object 'GitCloneResume.Native+INPUT_RECORD[]' 4

    # With no console there is nothing to read, so this path either returns
    # harmlessly or throws and disables mouse. Both are acceptable; losing the
    # keyboard is not.
    Receive-GcrMouseInput
    Say ("  OK   Receive-GcrMouseInput survived (mouseReady={0}, faults={1})" -f $script:GcrMouseReady, $script:GcrMouseFaults)

    # Whatever happened, the keyboard must still deliver a key.
    $script:GcrPendingInput.Clear()
    [void]$script:GcrPendingInput.Add((New-Object System.ConsoleKeyInfo([char]0, [ConsoleKey]::Enter, $false, $false, $false)))
    $k3 = Read-GcrTuiKey -TimeoutMs 0
    $okKey = ($null -ne $k3 -and $k3.Key -eq [ConsoleKey]::Enter)
    Say ("  {0} keyboard still delivers a key afterwards: {1}" -f $(if ($okKey) { "OK  " } else { "FAIL" }), $(if ($null -eq $k3) { "null" } else { $k3.Key }))

    # And a mouse fault must retire mouse support instead of leaving it half-on.
    $script:GcrMouseReady = $true
    $script:GcrMouseFaults = 1
    Disable-GcrMouse
    Say ("  {0} Disable-GcrMouse clears the ready flag: {1}" -f $(if (-not $script:GcrMouseReady) { "OK  " } else { "FAIL" }), $script:GcrMouseReady)
} catch {
    Say ("  FAIL mouse-fault check threw: {0}" -f $_.Exception.Message)
} finally {
    $script:GcrMouseReady = $false
    $script:GcrMouseFaults = 0
}

$out | Set-Content -LiteralPath (Join-Path $PSScriptRoot "native-input-results.txt") -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
