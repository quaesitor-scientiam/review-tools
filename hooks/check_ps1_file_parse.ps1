# PostToolUse hook for Write|Edit: when a PowerShell script file (.ps1/.psm1/.psd1)
# was written, parse the whole file and report parse errors back to Claude.
# PowerShell parses a script completely before running it, so one parse error
# (e.g. "$m:$u" in a double-quoted string) means NOTHING in the file runs when it
# is executed later with -File or &. Catch it at write time instead.
# Complements check_powershell_parse.ps1 (PreToolUse on the PowerShell tool).
# Fails open: unreadable input or a missing file is ignored.

$ErrorActionPreference = 'Stop'
try {
	$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
	$path = [string]$payload.tool_input.file_path
	if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$payload.tool_response.filePath }
} catch {
	exit 0
}
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
if ([IO.Path]::GetExtension($path).ToLowerInvariant() -notin '.ps1', '.psm1', '.psd1') { exit 0 }
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }

$tokens = $null
$errors = $null
try {
	[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
} catch {
	exit 0
}
if (-not $errors -or $errors.Count -eq 0) { exit 0 }

$lines = foreach ($e in $errors | Select-Object -First 5) {
	$line = $e.Extent.StartLineNumber
	$col = $e.Extent.StartColumnNumber
	$text = $e.Extent.Text
	if ($text.Length -gt 60) { $text = $text.Substring(0, 60) + '...' }
	"line ${line}, col ${col}: $($e.Message) [near: $text]"
}
$more = if ($errors.Count -gt 5) { "`n(+$($errors.Count - 5) more)" } else { '' }
$reason = "PowerShell parse error in ${path} - running this file would execute NOTHING. Fix it before running:`n" +
	($lines -join "`n") + $more +
	"`nCommon cause: `"`$name:`" inside a double-quoted string; write `"`${name}:`" or `"`$(`$name):`"."

@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
