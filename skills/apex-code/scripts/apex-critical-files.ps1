# The source of truth is apex-governance SKILL.md, Section "Hard blocks" and
# Section "Critical files". A divergent second copy of this pattern set fails
# open, so there is exactly one executable home. A future integrity sweep
# reconciles this file against the governance prose.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [switch]$Test,

    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Paths,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalPaths
)

# Split comma-packed arguments before classification. Without this, callers that pass
# multiple paths in one element fail open because no individual critical path is seen.
$inputPaths = @($Paths) + @($AdditionalPaths)
$Paths = @(
    foreach ($inputPath in $inputPaths) {
        foreach ($piece in ([string]$inputPath -split ',')) {
            $trimmedPath = $piece.Trim()
            if ($trimmedPath) {
                $trimmedPath
            }
        }
    }
)

$dependencyBasenames = @{
    'package.json'             = $true
    'pyproject.toml'           = $true
    'cargo.toml'               = $true
    'go.mod'                   = $true
    'go.sum'                   = $true
    'gemfile'                  = $true
    'composer.json'            = $true
    'requirements.txt'         = $true
    'pipfile'                  = $true
    'pom.xml'                  = $true
    'build.gradle'             = $true
    'build.gradle.kts'         = $true
    'package.swift'            = $true
    'pubspec.yaml'             = $true
    'mix.exs'                  = $true
    'packages.config'          = $true
    'directory.packages.props' = $true
    'package-lock.json'        = $true
    'pnpm-lock.yaml'           = $true
}

$ciBasenames = @{
    '.gitlab-ci.yml'          = $true
    '.travis.yml'             = $true
    'azure-pipelines.yml'     = $true
    'bitbucket-pipelines.yml' = $true
    'jenkinsfile'             = $true
}

$anyHardBlock = $false
$anyCritical = $false

foreach ($path in $Paths) {
    $originalPath = [string]$path
    $normalizedPath = $originalPath.Replace('\', '/').ToLowerInvariant()
    if ($normalizedPath.StartsWith('./')) {
        $normalizedPath = $normalizedPath.Substring(2)
    }

    if ($normalizedPath -match '(^|/)docs/audit(/|$)') {
        Write-Output ("HARDBLOCK {0}: audit" -f $originalPath)
        $anyHardBlock = $true
        continue
    }

    $components = @($normalizedPath -split '/')
    $basename = $components[$components.Count - 1]
    $category = $null

    # Classify private keys and certificate stores explicitly; omitting them lets
    # credential-bearing files fail open as ordinary paths.
    if (($basename -eq 'id_rsa') -or
        ($basename -eq 'id_ed25519') -or
        ($basename -match '\.(key|pem|pfx|p12|jks|keystore)$')) {
        $category = 'keys-certs'
    }
    elseif ($normalizedPath -match '(^|/)(\.env|[^/]*\.env)(\.[^/]*)?$') {
        $category = 'secrets-env'
    }
    elseif (($normalizedPath -match '(^|/)migrations(/|$)') -or
            ($normalizedPath -match '(^|/)alembic/versions(/|$)')) {
        $category = 'migrations'
    }
    else {
        foreach ($component in $components) {
            $lastDot = $component.LastIndexOf('.')
            if ($lastDot -ge 0) {
                $stem = $component.Substring(0, $lastDot)
            }
            else {
                $stem = $component
            }

            if (($stem -ne 'author') -and ($stem -ne 'authors') -and
                ($stem -match '^(auth|oauth|crypto|middleware)')) {
                $category = 'auth'
                break
            }
        }
    }

    if (($null -eq $category) -and
        (($normalizedPath -match '(^|/)\.github/workflows(/|$)') -or
         ($normalizedPath -match '(^|/)\.circleci(/|$)') -or
         $ciBasenames.ContainsKey($basename))) {
        $category = 'ci'
    }

    if (($null -eq $category) -and
        ($dependencyBasenames.ContainsKey($basename) -or
         ($normalizedPath -match '(^|/)[^/]*\.lock$'))) {
        $category = 'deps'
    }

    if (($null -eq $category) -and
        (($basename -match '\.tf(vars)?$') -or
         ($basename -match '^dockerfile(\..+)?$') -or
         ($basename -eq 'docker-compose.yml') -or
         ($basename -eq 'docker-compose.yaml') -or
         ($normalizedPath -match '(^|/)(k8s|kubernetes)(/|$)') -or
         ($basename -eq 'chart.yaml') -or
         ($basename -eq 'values.yaml'))) {
        $category = 'infra'
    }

    if (($null -eq $category) -and
        (($normalizedPath.Contains('secret')) -or
         ($normalizedPath.Contains('credential')))) {
        $category = 'secret-in-path'
    }

    if (($null -eq $category) -and
        (($normalizedPath -match '(^|/)hooks(/|$)') -or
         ($normalizedPath -match '(^|/)\.git/hooks(/|$)') -or
         ($normalizedPath -match '(^|/)\.githooks(/|$)') -or
         ($normalizedPath -match '(^|/)\.husky(/|$)'))) {
        $category = 'hooks'
    }

    if (($null -eq $category) -and
        (($normalizedPath -match '(^|/)\.claude/settings(\.local)?\.json$') -or
         ($normalizedPath -eq 'settings.json') -or
         ($normalizedPath -eq 'settings.local.json'))) {
        $category = 'permission-settings'
    }

    if ($null -ne $category) {
        Write-Output ("CRITICAL {0}: {1}" -f $originalPath, $category)
        $anyCritical = $true
    }
}

if ($anyHardBlock) {
    exit 11
}

if ($anyCritical) {
    exit 10
}

exit 0
