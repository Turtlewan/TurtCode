# coding-git-status.ps1
# UserPromptSubmit hook — injects current git dirty-file count into context (coding mode only).

# Only run in coding mode (DeepSeek backend)
$baseUrl = $env:ANTHROPIC_BASE_URL
if (-not ($baseUrl -match "deepseek")) {
    exit 0
}

# Only run inside a git repo
$isGit = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) {
    exit 0
}

# Count uncommitted files (staged + unstaged, excluding untracked)
$status = git status --porcelain 2>$null
$lines = ($status -split "`n") | Where-Object { $_ -match "^[ MADRCU?]{2}" -and $_ -notmatch "^\?\?" }
$count = $lines.Count

if ($count -eq 0) {
    exit 0
}

# Output additionalContext JSON for Claude to read
$files = $lines | ForEach-Object { $_.Substring(3).Trim() }
$fileList = $files -join ", "

$output = @{
    additionalContext = "[GIT STATUS] $count file(s) have uncommitted changes: $fileList"
} | ConvertTo-Json -Compress

Write-Output $output
exit 0
