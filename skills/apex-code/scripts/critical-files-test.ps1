[CmdletBinding()]
param()

$testCases = @(
    [pscustomobject]@{
        Name = 'TIER-1 audit file'
        Paths = @('docs/audit/log.md')
        ExitCode = 11
        Matches = @(@('HARDBLOCK', 'audit'))
    }
    [pscustomobject]@{
        Name = 'Slashless grant - audit directory'
        Paths = @('docs/audit')
        ExitCode = 11
        Matches = @(@('HARDBLOCK', 'audit'))
    }
    [pscustomobject]@{
        Name = 'Slashless grant - migrations directory'
        Paths = @('migrations')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'migrations'))
    }
    [pscustomobject]@{
        Name = 'Slashless grant - husky directory'
        Paths = @('.husky')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'hooks'))
    }
    [pscustomobject]@{
        Name = 'Slashless grant - alembic versions directory'
        Paths = @('alembic/versions')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'migrations'))
    }

    [pscustomobject]@{
        Name = 'TIER-2 positive - secrets-env'
        Paths = @('config/.env')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'secrets-env'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - migrations'
        Paths = @('migrations/0001_init.sql')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'migrations'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - auth'
        Paths = @('src/auth/login.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - ci'
        Paths = @('.github/workflows/build.yml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'ci'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - deps'
        Paths = @('package.json')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - infra'
        Paths = @('infra/main.tf')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'infra'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - secret-in-path'
        Paths = @('config/my-secret-token.json')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'secret-in-path'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - hooks'
        Paths = @('hooks/pre-commit')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'hooks'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - permission-settings'
        Paths = @('.claude/settings.json')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'permission-settings'))
    }
    [pscustomobject]@{
        Name = 'TIER-2 positive - keys-certs'
        Paths = @('certs/service.pem')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'keys-certs'))
    }

    [pscustomobject]@{
        Name = 'Auth prefix - authentication'
        Paths = @('src/authentication/login.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - authenticator'
        Paths = @('src/authenticator/svc.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - authorization'
        Paths = @('src/authorization/policy.py')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - authz'
        Paths = @('src/authz/guard.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - cryptography'
        Paths = @('lib/cryptography/key.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - underscore separator'
        Paths = @('src/auth_service.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - hyphen separator'
        Paths = @('src/auth-service.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - crypto hyphen'
        Paths = @('lib/crypto-utils.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }
    [pscustomobject]@{
        Name = 'Auth prefix - middleware'
        Paths = @('src/middleware/logging.ts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'auth'))
    }

    [pscustomobject]@{
        Name = 'CI extra - Travis'
        Paths = @('.travis.yml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'ci'))
    }
    [pscustomobject]@{
        Name = 'CI extra - Bitbucket Pipelines'
        Paths = @('bitbucket-pipelines.yml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'ci'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - uv lock'
        Paths = @('uv.lock')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - npm lock'
        Paths = @('package-lock.json')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - pnpm lock'
        Paths = @('pnpm-lock.yaml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - Maven'
        Paths = @('pom.xml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - Gradle Kotlin'
        Paths = @('build.gradle.kts')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - Swift'
        Paths = @('Package.swift')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - Dart'
        Paths = @('pubspec.yaml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - Elixir'
        Paths = @('mix.exs')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - NuGet packages config'
        Paths = @('packages.config')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Dependency extra - central package props'
        Paths = @('Directory.Packages.props')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'deps'))
    }
    [pscustomobject]@{
        Name = 'Infrastructure extra - Kubernetes'
        Paths = @('k8s/deployment.yaml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'infra'))
    }
    [pscustomobject]@{
        Name = 'Infrastructure extra - Helm chart'
        Paths = @('helm/Chart.yaml')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'infra'))
    }
    [pscustomobject]@{
        Name = 'Hooks extra - husky hook'
        Paths = @('.husky/pre-commit')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'hooks'))
    }

    [pscustomobject]@{
        Name = 'Tier dominance - hard-block and critical batch'
        Paths = @('docs/audit/x.md', 'config/.env')
        ExitCode = 11
        Matches = @(
            @('HARDBLOCK', 'audit'),
            @('CRITICAL', 'secrets-env')
        )
    }
    [pscustomobject]@{
        Name = 'Normalization - backslash separator'
        Paths = @('config\.env')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'secrets-env'))
    }
    [pscustomobject]@{
        Name = 'Normalization - mixed case'
        Paths = @('Config/.ENV')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'secrets-env'))
    }
    [pscustomobject]@{
        Name = 'Normalization - comma-joined pair'
        Paths = @('src/main.ts, config/.env')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'secrets-env'))
    }
    [pscustomobject]@{
        Name = 'Normalization - trailing comma skips blank piece'
        Paths = @('src,')
        ExitCode = 0
        Matches = @()
    }

    [pscustomobject]@{
        Name = 'Non-match - dispatch script'
        Paths = @('skills/apex-code/scripts/codex-dispatch.ps1')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - reviewer agent'
        Paths = @('agents/apex-reviewer.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - status document'
        Paths = @('docs/status.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
        ExactOutput = 'CRITICAL docs/status.md: host-state'
    }
    [pscustomobject]@{
        Name = 'Host-state positive - root AGENTS'
        Paths = @('AGENTS.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state positive - root CLAUDE'
        Paths = @('CLAUDE.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state positive - changes prefix'
        Paths = @('docs/changes/x.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state positive - handoff prefix'
        Paths = @('docs/handoff/2026-07-17.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state positive - root run ledger basename'
        Paths = @('codex-run-ledger.jsonl')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state positive - nested run ledger basename'
        Paths = @('docs/progress/codex-run-ledger.jsonl')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state normalization - repeated leading dot slash'
        Paths = @('././docs/status.md')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state normalization - trailing slash'
        Paths = @('docs/status.md/')
        ExitCode = 10
        Matches = @(@('CRITICAL', 'host-state'))
    }
    [pscustomobject]@{
        Name = 'Host-state overlap - changes auth path'
        Paths = @('docs/changes/auth-plan.md')
        ExitCode = 10
        Matches = @()
        AnyCriticalCategory = @('host-state', 'auth')
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - status sibling'
        Paths = @('docs/status-report.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - nested agents'
        Paths = @('src/agents.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - nested claude'
        Paths = @('sub/claude.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - changesets near miss'
        Paths = @('docs/changesets/x')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - nested changes prefix'
        Paths = @('nested/docs/changes/x.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Host-state anchored negative - nested handoff prefix'
        Paths = @('x/docs/handoff/y.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - README'
        Paths = @('README.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - VS Code settings'
        Paths = @('.vscode/settings.json')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - IntelliJ workspace'
        Paths = @('.idea/workspace.xml')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - authors document decoy'
        Paths = @('authors.md')
        ExitCode = 0
        Matches = @()
    }
    [pscustomobject]@{
        Name = 'Non-match - author directory decoy'
        Paths = @('AUTHOR/notes.md')
        ExitCode = 0
        Matches = @()
    }
)

$failures = 0
$passed = 0

foreach ($testCase in $testCases) {
    $output = @(& (Join-Path $PSScriptRoot 'apex-critical-files.ps1') -Test -Paths @($testCase.Paths))
    $actualExitCode = $LASTEXITCODE
    $problems = @()

    if ($actualExitCode -ne $testCase.ExitCode) {
        $problems += "exit expected $($testCase.ExitCode), actual $actualExitCode"
    }

    $expectedMatches = @($testCase.Matches)
    if (($expectedMatches.Count -gt 0) -and ($expectedMatches[0] -is [string])) {
        $expectedMatches = ,$expectedMatches
    }

    foreach ($expectedMatch in $expectedMatches) {
        $keyword = $expectedMatch[0]
        $category = $expectedMatch[1]
        $pattern = '^{0}\s+.*:\s*{1}\s*$' -f [regex]::Escape($keyword), [regex]::Escape($category)
        if (-not ($output | Where-Object { [string]$_ -match $pattern })) {
            $problems += "output missing $keyword line with category $category"
        }
    }

    if ($null -ne $testCase.PSObject.Properties['ExactOutput']) {
        if (-not ($output -ccontains $testCase.ExactOutput)) {
            $problems += "output missing exact line '$($testCase.ExactOutput)'"
        }
    }

    if ($null -ne $testCase.PSObject.Properties['AnyCriticalCategory']) {
        $categoryAlternatives = @($testCase.AnyCriticalCategory)
        $hasAllowedCategory = $output | Where-Object {
            $line = [string]$_
            $categoryAlternatives | Where-Object {
                $line -match ('^CRITICAL\s+.*:\s*{0}\s*$' -f [regex]::Escape($_))
            }
        }
        if (-not $hasAllowedCategory) {
            $problems += "output missing CRITICAL line with any allowed category: $($categoryAlternatives -join ', ')"
        }
    }

    $renderedOutput = if ($output.Count -eq 0) { '<none>' } else { $output -join ' | ' }
    if ($problems.Count -eq 0) {
        $passed++
        Write-Output ("PASS: {0} -- expected exit {1}, actual {2}; output: {3}" -f
            $testCase.Name, $testCase.ExitCode, $actualExitCode, $renderedOutput)
    }
    else {
        $failures++
        Write-Output ("FAIL: {0} -- expected exit {1}, actual {2}; assertions: {3}; output: {4}" -f
            $testCase.Name, $testCase.ExitCode, $actualExitCode,
            ($problems -join '; '), $renderedOutput)
    }
}

Write-Output ("SUMMARY: {0} passed, {1} failed, {2} total" -f
    $passed, $failures, $testCases.Count)

if ($failures -gt 0) {
    exit 1
}

exit 0
