$ErrorActionPreference = 'Stop'

$url = $env:ANTHROPIC_BASE_URL
if (-not $url) { $url = '(unset - default Anthropic)' }
$isDeepSeek = $url -like '*deepseek*'

$handoffContent = ''

if ($isDeepSeek) {
    $mode = 'CODING'
    $backend = 'DeepSeek'
    $policy = @"
Mode: CODING (DeepSeek backend)
You MAY: edit source code, run build/test/lint commands, complete implementation tasks.
You SHOULD: look for technical change specs in docs/changes/*.md (or wherever the user keeps them) and execute them. After completing each spec, update its status (e.g., mark Done at top, or move the file to docs/changes/done/).
"@
} else {
    $mode = 'PLANNING'
    $backend = 'Anthropic (Opus or other Claude model)'
    $policy = @"
Mode: PLANNING (Anthropic backend)
You MUST NOT: edit source code files. The PreToolUse hook will hard-block Write/Edit on non-.md files.
You SHOULD: produce technical change specifications as Markdown files under docs/changes/<short-name>.md. Each spec must include:
  1. Scope: one-paragraph summary of the change.
  2. Files to change: full paths.
  3. Exact changes: code-level detail (signatures, new functions, modifications). Pseudocode or full snippets.
  4. Acceptance criteria: how to verify it works.
  5. Commands to run: build, test, lint.
  6. Risks / open questions.
A later DeepSeek session will execute these specs.

At the START of this session:
  - Summarise the latest handoff doc (injected below) back to the user.
  - List any pending specs in docs/changes/ and ask which to focus on.
"@

    # Look for the latest handoff doc in the current project
    $handoffDir = Join-Path (Get-Location) 'docs/handoff'
    if (Test-Path $handoffDir) {
        $latest = Get-ChildItem $handoffDir -Filter '*.md' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $handoffContent = "`n`n---`n## Latest handoff doc: $($latest.Name)`n`n" + (Get-Content $latest.FullName -Raw)
        }
    }
    if (-not $handoffContent) {
        $handoffContent = "`n`n---`n## No handoff doc found`nThis appears to be a new project or the first planning session. No prior build context available."
    }
}

$ctx = "## Active LLM backend: $backend`n## ANTHROPIC_BASE_URL: $url`n`n$policy$handoffContent"

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $ctx
    }
} | ConvertTo-Json -Compress -Depth 5

Write-Output $payload
