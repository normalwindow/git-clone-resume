# Reference implementation for the differential tests in bench\test-width.ps1.
#
# These are the width/truncate/format helpers EXACTLY as they were in
# git-clone-resume.tui.ps1 before the performance work (taken verbatim from git
# HEAD:git-clone-resume.tui.ps1). The rewritten versions in the live file must
# keep producing byte-identical output, so the tests compare against these.
#
# Do not "improve" anything here: it is a frozen oracle, not production code.
# Kept in its own directory so it is never dot-sourced by the real scripts, and
# loaded into a throwaway module by the test so the names do not clash.

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
