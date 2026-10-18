# PreToolUse hook for the PowerShell tool: parse the command before it runs.
# PowerShell parses the WHOLE script before executing anything, so a single
# parse error (e.g. "$b: text" in a double-quoted string) means no line runs.
# Blocking here turns that into immediate feedback instead of a silent no-op.
# Fails open: if the hook input can't be read, the call is allowed.

$ErrorActionPreference = 'Stop'
try {
	$raw = [Console]::In.ReadToEnd()
	$payload = $raw | ConvertFrom-Json
	$command = [string]$payload.tool_input.command
} catch {
	exit 0
}
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
if (-not $errors -or $errors.Count -eq 0) { exit 0 }

$lines = foreach ($e in $errors | Select-Object -First 5) {
	$line = $e.Extent.StartLineNumber
	$col = $e.Extent.StartColumnNumber
	$text = $e.Extent.Text
	if ($text.Length -gt 60) { $text = $text.Substring(0, 60) + '...' }
	"line ${line}, col ${col}: $($e.Message) [near: $text]"
}
$more = if ($errors.Count -gt 5) { "`n(+$($errors.Count - 5) more)" } else { '' }
$reason = "PowerShell parse error - nothing in this script would run. Fix and resend:`n" +
	($lines -join "`n") + $more +
	"`nCommon cause: `"`$name:`" inside a double-quoted string; write `"`${name}:`" or `"`$(`$name):`"."

@{
	hookSpecificOutput = @{
		hookEventName            = 'PreToolUse'
		permissionDecision       = 'deny'
		permissionDecisionReason = $reason
	}
} | ConvertTo-Json -Depth 4 -Compress
exit 0
