# detect_sibling_arms.ps1 — list all arms of every match block that contains
# a given pattern, flagging arms that are missing it.
#
# Canonical miss (PR #27413): SETTINGS arm of dispatch_frame got !handshaked;
# the PING arm in the same match had the identical gap and never caught.
#
# Usage: pwsh detect_sibling_arms.ps1 <file> <pattern>
#   <file>     path to the V source file (Windows or WSL path)
#   <pattern>  regex pattern identifying the guard/check just added
#              e.g. 'handshaked'  or  'flow_size'  or  'reset_stream'
#
# Output: for each match block containing <pattern>, lists all arms and marks
#   [HAS]     — arm body contains the pattern
#   [MISSING] — arm body does not; review this arm for the same deficiency
#
# Exit 0 always — enumerate-and-verify tool, not a pass/fail gate.

param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$Pattern
)

if (-not (Test-Path $File)) { Write-Error "File not found: $File"; exit 2 }

$lines = Get-Content $File
$total = $lines.Count

Write-Host "=== sibling-arm scan: $File  pattern='$Pattern' ==="

# Find all lines containing the pattern (1-based)
$hitLines = @()
for ($i = 0; $i -lt $total; $i++) {
    if ($lines[$i] -match $Pattern) { $hitLines += ($i + 1) }
}

if ($hitLines.Count -eq 0) {
    Write-Host "(no lines matching '$Pattern' found)"
    exit 0
}

# For each hit, find its enclosing match block (scan backward)
$processedMatches = @{}

foreach ($hit in $hitLines) {
    $matchLine = 0
    for ($i = $hit - 1; $i -ge 1; $i--) {
        if ($lines[$i - 1] -match '^\t*match\b') { $matchLine = $i; break }
    }
    if ($matchLine -eq 0) { continue }
    if ($processedMatches.ContainsKey($matchLine)) { continue }
    $processedMatches[$matchLine] = $true

    $matchSig = $lines[$matchLine - 1].TrimStart()
    Write-Host ""
    Write-Host "Match block at line $matchLine : $matchSig"

    # Count leading tabs on the match line
    $matchTabs = ($lines[$matchLine - 1] -replace '^(\t*).*', '$1').Length
    $armTabs   = $matchTabs + 1
    $armPrefix = "`t" * $armTabs

    # Scan forward from matchLine+1 collecting arms
    # Arm label: line starts with exactly armTabs tabs followed by H2* or else
    # Block ends when a non-blank line has <= matchTabs leading tabs

    $arms = [System.Collections.Generic.List[hashtable]]::new()
    $currentArm = $null

    for ($j = $matchLine; $j -lt $total; $j++) {
        $line = $lines[$j]   # 0-based; $j corresponds to 1-based line $j+1
        $stripped = $line.TrimStart()
        if ($stripped -eq '') {
            if ($null -ne $currentArm) { $currentArm.Body += "`n$line" }
            continue
        }

        $lineTabs = ($line -replace '^(\t*).*', '$1').Length

        # Block ended
        if ($lineTabs -le $matchTabs -and $j -gt $matchLine) { break }

        # Arm label line
        if ($lineTabs -eq $armTabs -and ($stripped -match '^(H2[A-Za-z]+|else)\s')) {
            if ($null -ne $currentArm) { $arms.Add($currentArm) }
            $currentArm = @{ LineNo = ($j + 1); Label = $stripped; Body = $line }
            continue
        }

        if ($null -ne $currentArm) { $currentArm.Body += "`n$line" }
    }
    if ($null -ne $currentArm) { $arms.Add($currentArm) }

    if ($arms.Count -eq 0) {
        Write-Host "  (no typed arms found — check manually)"
        continue
    }

    foreach ($arm in $arms) {
        $hasPattern = $arm.Body -match $Pattern
        $flag = if ($hasPattern) { "[HAS]    " } else { "[MISSING]" }
        Write-Host ("  line {0,-5} {1}  {2}" -f $arm.LineNo, $flag, $arm.Label)
    }
    Write-Host "  ---"
    Write-Host "  [MISSING] arms may have the same deficiency as the arm with '$Pattern'."
}

Write-Host ""
