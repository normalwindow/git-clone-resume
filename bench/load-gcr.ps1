# Extracts the function definitions from git-clone-resume.ps1 / .tui.ps1 and
# returns them as a single scriptblock, so a harness can dot-source them and get
# real `function name { }` bindings with `$script:` pointing at the harness.
#
#     . .\bench\load-gcr.ps1
#     . (Get-GcrFunctionBlock -Paths @('..\a.ps1','..\b.ps1'))
#
# Why not Set-Item function:...: registering a [scriptblock]::Create()'d
# definition leaves `$script:` inside that function bound to a throwaway scope,
# so every `$script:GcrTui.X = ...` assignment silently vanishes. Building a
# real scriptblock from real definition text and dot-sourcing it keeps the
# binding, which matters because the TUI keeps all its state in `$script:GcrTui`.
#
# Top-level statements are deliberately NOT included: the real scripts do a lot
# of work (and can `exit`) at file scope, which must not run in a harness.

Set-StrictMode -Version Latest

function Get-GcrFunctionBlock {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $all = New-Object System.Text.StringBuilder
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($p in $Paths) {
        $resolved = (Resolve-Path -LiteralPath $p).Path
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw ("parse errors in {0}: {1}" -f $resolved, ($errors[0].Message))
        }

        $defs = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($d in $defs) {
            [void]$all.AppendLine($d.Extent.Text)
            [void]$names.Add($d.Name)
        }
    }

    return [pscustomobject]@{ Block = [scriptblock]::Create($all.ToString()); Names = $names }
}
