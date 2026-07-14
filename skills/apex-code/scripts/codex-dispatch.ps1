# Durable Codex dispatcher (ADR-033).
#
# Delivers a dispatch pack to `codex exec`, explicitly closes the child's stdin,
# and records the run in a durable JSONL ledger.  A no-output watchdog flags a
# stalled run but deliberately does not terminate it; process ownership remains
# with the caller.  `-Adopt` prints the newest matching run's worktree and diff.

[CmdletBinding()]
param(
    [string]$Spec,
    [string]$Task,
    [string]$Worktree,
    [string]$BaseSha,
    [string]$Phase,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$Effort = 'medium',
    [ValidateRange(1, 2147483647)]
    [int]$NoOutputTimeoutMin = 8,
    [switch]$Adopt,
    # The spec's '## Files to change' list. Given, the scope lock is ENFORCED (snapshot before
    # launch, diff + path-scoped revert after exit). Omitted, it is prose only -- and prose has
    # already failed: Codex has written outside a scope lock it was explicitly given.
    [string[]]$Authorized = @(),
    [switch]$SkipScopeCheck,
    # Two Codex workers in one working tree is a data race with a delete in it (see the guard below).
    # Wave-parallel dispatch requires ONE WORKTREE PER CONCURRENT TASK. This overrides the refusal.
    [switch]$AllowSharedWorktree,
    # Read-only gates (review, end-gate) auto-pin the tree and VOID their verdict if it moves under
    # them. This disables that. You almost never want it.
    [switch]$NoTreePin,
    [string]$Prompt,
    # Selects the --output-schema codex is constrained to. A review/end-gate pass returns
    # findings, not a build completion; constraining it to the build schema (whose
    # additionalProperties is false and which has no `findings` property) makes its entire
    # result structurally inexpressible and silently drops it.
    [ValidateSet('completion', 'endgate', 'review')]
    [string]$Schema = 'completion',
    # A review/end-gate pass must not be able to edit the tree it is judging. The wrapper was
    # built for build dispatches, so it hardcoded workspace-write; the standing Sol end-gate
    # inherited it and has been running with repo write access despite the runbook's
    # "never auto-edits anything" guarantee.
    [ValidateSet('workspace-write', 'read-only')]
    [string]$Sandbox = 'workspace-write',
    [string]$ScratchDirectory = $env:TEMP,
    [string]$CodexExecutable = 'codex',
    [string[]]$CodexExecutableArgumentPrefix = @()
)

$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value -replace '[<>:"/\\|?*]', '_')
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Quote with the CommandLineToArgvW / CreateProcess backslash rules.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# The ledger is deliberately GLOBAL (lives beside the dispatcher, not the target repo): -Adopt
# must be able to find a crashed run without knowing in advance which repo it happened in. Each
# dispatch's own log, by contrast, belongs with the repo it built -- so it lives under the
# target -Worktree's own docs\progress, consistent with every other apex-code Codex log.
$dispatcherRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

# The ledger and the logs live OUTSIDE EVERY REPO -- not merely outside the target repo.
#
# They used to sit under the dispatcher's own checkout (~/.claude/docs/progress/). That is fine until
# the tree being judged IS ~/.claude -- which is exactly what happens when this harness reviews
# itself, and what it has been doing all day. Then the ledger row, the status updates and the log all
# land inside the worktree under scope check, the harness's own writes read as unauthorized ones, and
# a clean authorized build exits 65.
#
# "Outside the target repo" was the wrong rule; it just moved the collision. The rule is: THE HARNESS
# MUST NOT WRITE INTO ANY TREE IT MIGHT JUDGE. A machine-local state directory, belonging to no repo,
# cannot collide with one.
$apexStateRoot = if ($env:APEX_STATE_DIR) { $env:APEX_STATE_DIR }
elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex' }
else { Join-Path $env:TEMP 'apex' }

# A caller can point APEX_STATE_DIR (or -ScratchDirectory) INSIDE a repo, which puts the harness's
# own artifacts back into a tree it may be judging -- the exact bug we just spent three rounds
# chasing, reintroduced through a parameter. Refuse it rather than trust the caller to know.
function Assert-NotInsideRepo {
    param([string]$Path, [string]$What)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { [System.IO.Directory]::CreateDirectory($Path) | Out-Null } catch { return }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $top = (& git -C $Path rev-parse --show-toplevel 2>$null) } catch { $top = $null } finally { $ErrorActionPreference = $previous }
    if ($top) {
        throw "$What resolves inside a git worktree ($top). The harness must never write into a tree it might judge. Point it somewhere outside every repo."
    }
}
Assert-NotInsideRepo -Path $apexStateRoot -What 'The APEX state directory'

# The gate helpers keep their own state (the scope snapshot, the tree pin) and BOTH defaulted to
# $env:TEMP independently. A TEMP that happens to sit inside the worktree therefore put the snapshot
# and the pin straight back into the judged tree -- through the one door the validation above did not
# cover. Give them a validated directory instead of letting them each guess.
$harnessStateDir = Join-Path $apexStateRoot 'gates'
[System.IO.Directory]::CreateDirectory($harnessStateDir) | Out-Null

$ledgerDirectory = Join-Path $apexStateRoot 'progress'
$ledgerPath = Join-Path $ledgerDirectory 'codex-run-ledger.jsonl'

# Carry the existing ledger over once, so -Adopt can still find a run recorded before the move.
$legacyLedger = Join-Path (Join-Path $dispatcherRoot 'docs\progress') 'codex-run-ledger.jsonl'
if ((Test-Path -LiteralPath $legacyLedger) -and -not (Test-Path -LiteralPath $ledgerPath)) {
    [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
    Copy-Item -LiteralPath $legacyLedger -Destination $ledgerPath -Force -ErrorAction SilentlyContinue
}
$schemaFile = switch ($Schema) {
    'endgate' { 'afk-endgate-schema.json' }
    'review' { 'codex-review-schema.json' }
    default { 'codex-completion-schema.json' }
}
$schemaPath = Join-Path $dispatcherRoot "skills\apex-code\references\$schemaFile"
$ledgerMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')

function Invoke-WithLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $acquired = $false
    try {
        try {
            $acquired = $ledgerMutex.WaitOne([TimeSpan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Timed out waiting for the Codex run-ledger lock.' }
        & $Action
    } finally {
        if ($acquired) { $ledgerMutex.ReleaseMutex() }
    }
}

function Add-LedgerRow {
    param([Parameter(Mandatory)][hashtable]$Row)

    Invoke-WithLedgerLock {
        [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
        $json = $Row | ConvertTo-Json -Compress -Depth 8
        [System.IO.File]::AppendAllText(
            $ledgerPath,
            $json + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Update-LedgerRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Changes
    )

    Invoke-WithLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath)) {
            throw "Codex run ledger does not exist: $ledgerPath"
        }

        $updated = $false
        $outputLines = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ($row.run_id -eq $RunId) {
                foreach ($change in $Changes.GetEnumerator()) {
                    $row | Add-Member -NotePropertyName $change.Key -NotePropertyValue $change.Value -Force
                }
                $updated = $true
                $row | ConvertTo-Json -Compress -Depth 8
            } else {
                $line
            }
        }

        if (-not $updated) { throw "Codex run ledger row not found for run_id $RunId." }

        # A same-directory temporary file plus File.Replace makes a completed
        # status update atomic for readers; the named mutex serializes wrappers.
        $replacementId = [guid]::NewGuid().ToString('N')
        $temporaryPath = "$($ledgerPath).$replacementId.tmp"
        $backupPath = "$($ledgerPath).$replacementId.bak"
        try {
            [System.IO.File]::WriteAllLines(
                $temporaryPath,
                [string[]]$outputLines,
                [System.Text.UTF8Encoding]::new($false)
            )
            [System.IO.File]::Replace($temporaryPath, $ledgerPath, $backupPath)
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        }
    }
}

# --- Worktree identity: CANONICAL, never lexical -------------------------------------------------
# Two dispatches into the same tree must recognise each other, or the sibling guards are decorative.
# String comparison cannot do that: `-Worktree .`, `C:\Users\User\.claude`, `c:/users/user/.claude`,
# a junction, and an 8.3 short path are five spellings of one directory. A ledger row written under
# one spelling is invisible to a scan using another -- so the seatbelt lets a second coder launch,
# and the airbag then fails to recognise it and deletes its work. Ask GIT for the identity: it
# resolves links and relative paths to the one true repo root.
function Get-WorktreeKey([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    $top = $null
    try {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $top = (& git -C $path rev-parse --show-toplevel 2>$null) } finally { $ErrorActionPreference = $previous }
    } catch { $top = $null }
    if (-not $top) {
        # Not a git repo (or git unavailable): fall back to the canonical filesystem path.
        try { $top = [System.IO.Path]::GetFullPath($path) } catch { $top = $path }
    }
    return (([string]$top) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# --- Liveness: a PID alone is NOT an identity ----------------------------------------------------
# Windows recycles PIDs. A stale `running` row whose PID has been reused by an unrelated long-lived
# process would make Get-Process succeed forever: every future dispatch exits 71 and every -Adopt
# exits 75, for a coder that died hours ago. So a PID only counts as OUR process if it also STARTED
# AT OR AFTER the moment we recorded the row. A recycled PID is necessarily younger than the row it
# is impersonating... but the reverse is what we can actually check: a process that started BEFORE
# the ledger row was written cannot be the child that row created.
# A PID IS NOT AN IDENTITY. A (pid, start-time) PAIR IS.
#
# Windows recycles PIDs. The first attempt at this compared the process's StartTime against the
# ledger row's `started` and accepted anything that began at-or-after it -- which is exactly
# BACKWARDS for the case it was meant to catch: a recycled PID starts LATER than the row, so it
# sailed through and an unrelated process read as a live coder forever. It also rejected a
# legitimate long-lived launcher that started before the row, which would have let a concurrent
# launch through. Wrong in both directions at once.
#
# So record the process's OWN start time when the pid is recorded, and require an exact match. A
# recycled pid necessarily has a different start time. There is nothing to infer.
function Get-ProcessStamp([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { return $p.StartTime.ToUniversalTime().ToString('o') } catch { return 'unknown' }
}

function Test-ProcessIs {
    param([int]$ProcessId, [string]$Stamp, [switch]$Strict)

    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }

    # -Strict: POSITIVE identification only. Used to answer "is this definitely still our coder?",
    # which must never be overruled by a heuristic like the age rule.
    if (-not $Stamp -or $Stamp -eq 'unknown') { return (-not $Strict) }
    try {
        $actual = $p.StartTime.ToUniversalTime()
        $expected = ([datetime]$Stamp).ToUniversalTime()
        # The stamp is read from the process ITSELF at the moment its pid is recorded, so an exact
        # match is available -- no tolerance is needed, and a 2-second window is wide enough for
        # Windows to recycle a short-lived coder's pid onto an unrelated process started inside it,
        # which would then be positively identified as the coder (wedging dispatches at 71 and
        # adoption at 75). A 50ms window absorbs only serialization jitter.
        return ([math]::Abs(($actual - $expected).TotalMilliseconds) -lt 50)
    } catch {
        return (-not $Strict)   # protected process: cannot read StartTime. Fail SAFE unless -Strict.
    }
}

function Test-LedgerRowLive {
    param([Parameter(Mandatory)]$Row)

    # A VERIFIED process is live, however old the row is. The age rule below exists only to expire
    # rows we CANNOT verify -- it must never overrule positive evidence. Applying it first would
    # declare a legitimately long-running dispatch dead at the 12h mark and let a second coder launch
    # into the tree it is still writing, which is the exact collision this guard exists to prevent.
    if ($Row.pid -and (Test-ProcessIs -ProcessId ([int]$Row.pid) -Stamp ([string]$Row.pid_start) -Strict)) { return $true }
    if ($Row.launcher_pid -and (Test-ProcessIs -ProcessId ([int]$Row.launcher_pid) -Stamp ([string]$Row.launcher_start) -Strict)) { return $true }

    # Unverifiable (stamp 'unknown', or StartTime unreadable): fail SAFE and call it live -- but only
    # for a bounded time. Otherwise a recycled PID owned by a long-lived system process, or a row
    # whose stamp could never be read, refuses every future dispatch into that worktree until reboot.
    $unverifiable = ($Row.pid -and (Test-ProcessIs -ProcessId ([int]$Row.pid) -Stamp ([string]$Row.pid_start))) -or
                    ($Row.launcher_pid -and (Test-ProcessIs -ProcessId ([int]$Row.launcher_pid) -Stamp ([string]$Row.launcher_start)))
    if (-not $unverifiable) { return $false }

    if ($Row.started) {
        try {
            $age = (Get-Date).ToUniversalTime() - ([datetime]$Row.started).ToUniversalTime()
            if ($age.TotalHours -gt 12) { return $false }   # unverifiable AND ancient: a corpse.
        } catch { }
    }
    return $true
}

# Every dispatch still running in a given worktree. There is deliberately NO task-name exclusion:
# excluding by name meant two dispatches of the SAME task name into one tree each ignored the other
# and both launched -- the precise collision the guard exists to prevent. This is only ever called
# BEFORE this run's own row is written, so there is nothing of ours to exclude.
function Get-LiveDispatches {
    param([Parameter(Mandatory)][string]$WorktreeKey)

    if (-not (Test-Path -LiteralPath $ledgerPath)) { return @() }
    $live = @()
    foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        # 'stalled' is STILL LIVE: the watchdog flags a quiet run and deliberately does NOT kill it.
        # 'adopting' is LIVE: adoption is still running that run's gates. Treating it as terminal
        # freed the worktree mid-adoption -- and if adoption then threw (a missing helper), the row
        # stayed 'adopting' forever while the next dispatch happily launched into the same tree.
        if ($row.status -ne 'running' -and $row.status -ne 'stalled' -and $row.status -ne 'adopting') { continue }
        if ([string]$row.worktree_key -ne $WorktreeKey) { continue }
        if (Test-LedgerRowLive -Row $row) { $live += $row }
    }
    return $live
}

function Invoke-Adopt {
    # Spec+Phase alone does not identify a run. Adoption CLOSES the row it selects and reports its
    # verdict as if it were the one you asked about -- so selecting the wrong row means closing an
    # unrelated run as `adopted`, exiting 0, and leaving the run you actually cared about live and
    # unterminated. Demand enough to be sure.
    if ([string]::IsNullOrWhiteSpace($Spec) -or [string]::IsNullOrWhiteSpace($Phase)) {
        throw '-Adopt requires -Spec and -Phase.'
    }
    if ([string]::IsNullOrWhiteSpace($Worktree)) {
        throw '-Adopt requires -Worktree: two runs of the same spec/phase can exist in different worktrees, and adopting the wrong one closes it and leaves yours live.'
    }
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        throw "Codex run ledger does not exist: $ledgerPath"
    }

    $match = Invoke-WithLedgerLock {
        $adoptKey = if ($Worktree) { Get-WorktreeKey $Worktree } else { $null }
        $matches = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ($row.spec -ne $Spec -or $row.phase -ne $Phase) { continue }
            # Filter on EVERY identifier the caller supplied. Matching spec+phase alone could adopt a
            # different task, in a different worktree -- closing that row as `adopted` and exiting 0,
            # while the run actually asked about stayed live and unterminated.
            if ($Task -and $row.task -ne $Task) { continue }
            # NEVER adopt a row that already reached a terminal state. Selecting "the newest row"
            # regardless of status meant a completed rerun B was re-closed as `adopted-done` while the
            # dead run A you were actually recovering stayed `running` forever.
            if ($row.status -notin @('running', 'stalled', 'adopting')) { continue }
            # A LEGACY row (migrated from before worktree_key existed) has no key. Deriving it from
            # the row's recorded worktree is right; treating "no key" as "matches anything" is how a
            # row from worktree B got adopted when worktree A was explicitly requested.
            $rowKey = if ($row.worktree_key) { [string]$row.worktree_key } elseif ($row.worktree) { Get-WorktreeKey ([string]$row.worktree) } else { '' }
            if ($rowKey -ne $adoptKey) { continue }
            $row
        }
        $matches | Sort-Object { [datetime]$_.started } -Descending | Select-Object -First 1
    }

    if ($null -eq $match) {
        throw "No Codex ledger row matches spec '$Spec' and phase '$Phase'."
    }

    # A dead dispatch call does NOT mean a dead coder. `codex exec` outlives the tool call that
    # launched it: a harness Bash timeout SIGTERMs the shell (exit 143), the child keeps working,
    # and a host that reads "my call died" as "the coder died" walks straight into recovery on a
    # tree that is still being written. On cap-deps-1b (2026-07-14) the coder kept writing for
    # 3.5 minutes after it was declared dead. Adopting a half-written tree is worse than waiting:
    # you verify and commit a torn build. So before showing anything, ask whether it is still alive.
    # 'stalled' is NOT dead. The watchdog flags a run with no output and deliberately does NOT kill
    # the child (process ownership stays with the caller). Checking liveness only for 'running' let
    # -Adopt hand back a half-written tree for a coder that was demonstrably still alive -- exactly
    # the failure this guard exists to prevent, reachable through the one status that means
    # "quiet, and still going".
    if (($match.status -eq 'running' -or $match.status -eq 'stalled') -and (Test-LedgerRowLive -Row $match)) {
        Write-Host "[adopt] THE CODER IS STILL RUNNING -- pid $($match.pid), status '$($match.status)'. Nothing to adopt." -ForegroundColor Yellow
        Write-Host "[adopt] Your dispatch CALL died; the coder did not. Do not verify, do not commit: the tree is still being written." -ForegroundColor Yellow
        Write-Host "[adopt] The completion signal is the report file, and only that file:" -ForegroundColor Yellow
        Write-Host "[adopt]   $($match.final_path)" -ForegroundColor Yellow
        Write-Host "[adopt] Wait for it to appear, then re-run -Adopt. To abandon instead, kill pid $($match.pid) deliberately." -ForegroundColor Yellow
        exit 75
    }

    # The coder is dead -- so ADOPT ITS VERDICT, not just its diff.
    #
    # This used to print `git diff base..HEAD` and exit with git's status. Two things wrong with
    # that. First, it never read the report: a child that exited `blocked` (or a review that returned
    # BLOCK) was adopted as a clean success. Second, `base..HEAD` shows only COMMITTED work, and the
    # coder is instructed never to commit -- so the diff was usually EMPTY. Adoption returned "no
    # changes, exit 0" for a run that had failed and left a tree full of them.
    #
    # (I claimed this was fixed in a review pack before I had written it. The reviewer read the code
    # instead of my summary, which is the only reason it is being fixed now.)
    Write-Output $match.worktree

    $adoptStatus = 'unknown'
    if ($match.final_path -and (Test-Path -LiteralPath $match.final_path -PathType Leaf)) {
        try {
            $adoptReport = Get-Content -LiteralPath $match.final_path -Raw | ConvertFrom-Json
            $adoptStatus = if ($adoptReport.status) { [string]$adoptReport.status } else { 'unknown' }
            # A report saying `done` does not undo a process that FAILED. The main path records
            # status:'failed' with the child's exit code; adoption used to derive `done` from the
            # report alone and rewrite the row as adopted-done, exiting 0 on a run that had failed.
            if ($match.status -eq 'failed' -and $adoptStatus -eq 'done') {
                Write-Host "[adopt] The report says 'done' but the run FAILED (exit $($match.error)). The process outranks the claim." -ForegroundColor Red
                $adoptStatus = 'blocked'
            }
            # Same coupling as the main path: a blocker or unresolved work contradicts `done`.
            if ($adoptReport.blocker -and $adoptStatus -eq 'done') { $adoptStatus = 'blocked' }
            elseif (@($adoptReport.unresolved).Count -gt 0 -and $adoptStatus -eq 'done') { $adoptStatus = 'done_with_concerns' }
            if ($adoptReport.PSObject.Properties.Name -contains 'verdict') {
                # Match the MAIN path's rules exactly. This used to test `BLOCK*` (prefix) while the
                # main path tested `*BLOCK*` (substring), so an end-gate verdict of "P1: block
                # handoff" was unmatched here, left $adoptStatus 'unknown', and adopted as EXIT 0.
                # Two copies of one rule is one copy too many; they diverged, and the weaker one
                # failed open.
                $v = ([string]$adoptReport.verdict).ToUpperInvariant()

                # Findings OUTRANK the verdict string, exactly as on the main path. A report saying
                # `verdict: CLEAN` while carrying a BLOCK finding is contradicting itself, and
                # adoption used to believe the cheerful half and exit 0.
                $adoptFindings = 0
                if ($adoptReport.findings) {
                    $adoptFindings = @($adoptReport.findings | Where-Object {
                        $sev = ([string]$_.severity).ToUpperInvariant()
                        $sev -and $sev -ne 'CLEAN' -and $sev -ne 'NONE' -and $sev -ne 'INFO'
                    }).Count
                }
                $hasBlockingFinding = $false
                if ($adoptReport.findings) {
                    $hasBlockingFinding = @($adoptReport.findings | Where-Object {
                        ([string]$_.severity).ToUpperInvariant() -like '*BLOCK*'
                    }).Count -gt 0
                }

                if ($v -like '*BLOCK*' -or $hasBlockingFinding) { $adoptStatus = 'blocked' }
                elseif ($v -like '*FLAG*' -or $v -like 'P1*' -or $v -like 'P2*' -or $adoptFindings -gt 0) { $adoptStatus = 'done_with_concerns' }
                elseif ($v -eq 'CLEAN' -or $v -eq 'PASS' -or $v -eq 'OK') { if ($adoptStatus -eq 'unknown') { $adoptStatus = 'done' } }
                else { $adoptStatus = 'blocked' }   # unrecognised verdict: fail closed
            }
            foreach ($u in @($adoptReport.unresolved)) { if ($u) { Write-Host "[adopt] UNRESOLVED: $u" -ForegroundColor Yellow } }
            if ($adoptReport.blocker) { Write-Host "[adopt] BLOCKER: $($adoptReport.blocker)" -ForegroundColor Red }
        } catch {
            $adoptStatus = 'blocked'
            Write-Host "[adopt] The report at $($match.final_path) is unparseable. Treating as blocked." -ForegroundColor Red
        }
    } else {
        Write-Host "[adopt] The coder is gone and wrote NO report. A missing verdict is not a passing one." -ForegroundColor Red
        $adoptStatus = 'blocked'
    }
    if ($adoptStatus -eq 'unknown') { $adoptStatus = 'blocked' }   # never adopt an unknown as a pass

    # Mark the row ADOPTING -- not adopted -- until the gates below have actually run. Writing the
    # terminal status here recorded `adopted-done` for a run that adoption then discovered had written
    # out of scope; and if adoption was killed between the two, the ledger was left holding a
    # SUCCESSFUL terminal row for an ungated run, which freed the worktree for the next dispatch.
    # A row is only terminal once the thing that makes it terminal has happened.
    try {
        Update-LedgerRow -RunId ([string]$match.run_id) -Changes @{
            status = 'adopting'; adopted = $true; report_status = $adoptStatus
        }
    } catch { Write-Host "[adopt] WARNING: could not update the ledger row: $($_.Exception.Message)" -ForegroundColor Yellow }

    # The working tree, not just commits: the coder leaves its work UNCOMMITTED by contract.
    & git -C $match.worktree --no-pager diff $match.base_sha
    & git -C $match.worktree --no-pager status --porcelain

    # ADOPTION MUST RUN THE GATES THE DEAD WRAPPER NEVER GOT TO RUN.
    #
    # Adoption exists precisely because the wrapper died -- which means the scope check and the tree
    # pin it had armed never fired. Reading only the coder's self-report and exiting 0 accepts the
    # coder's word for the one thing it is least able to judge. A killed wrapper plus an
    # out-of-scope write plus a `done` report used to adopt as a clean success.
    $adoptScopeExit = 0
    $adoptScript = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
    if ($match.scope_armed -and -not (Test-Path $adoptScript)) {
        throw "This run armed a scope check, but codex-scope-check.ps1 is missing ($adoptScript). Refusing to adopt: an armed gate that cannot run must not be silently skipped."
    }
    if ($match.tree_pin_label -and -not (Test-Path (Join-Path $PSScriptRoot 'tree-pin.ps1'))) {
        throw "This run armed a tree pin, but tree-pin.ps1 is missing. Refusing to adopt: an unpinned gate can bless a tree that moved under it."
    }
    if ($match.scope_armed -and (Test-Path $adoptScript)) {
        if ($match.scope_exit -ne $null -and $match.ended) {
            # The original wrapper already ran this check and recorded its result; the snapshot is
            # one-shot and is gone. Re-running would throw "No snapshot". Reuse the recorded verdict
            # rather than crashing -- a gate that already ran is not a gate that was skipped.
            $adoptScopeExit = [int]$match.scope_exit
            Write-Host "[adopt] scope check already ran for this run: exit $adoptScopeExit (reusing its result)." -ForegroundColor DarkGray
        }
        else {
            try {
                & $adoptScript -Check -Worktree $match.worktree -Task ([string]$match.scope_task) `
                    -Authorized @($match.authorized) -ExcludeRunId ([string]$match.run_id) -StateDirectory $harnessStateDir | Write-Host
                $adoptScopeExit = $LASTEXITCODE
            } catch {
                # No snapshot and no recorded result: the gate was armed and its evidence is gone, so
                # nothing can vouch for this run's scope. Fail closed.
                Write-Host "[adopt] The armed scope check cannot be replayed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "[adopt] Its evidence is gone, so nothing can vouch for this run's scope. Treating as a violation." -ForegroundColor Red
                $adoptScopeExit = 1
            }
        }
        if ($adoptScopeExit -ne 0) {
            Write-Host "[adopt] The adopted run wrote OUTSIDE its authorized set (scope exit $adoptScopeExit)." -ForegroundColor Red
        }
    }

    $adoptPinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
    if ($match.tree_pin_label -and (Test-Path $adoptPinScript)) {
        & $adoptPinScript -Verify -Worktree $match.worktree -Label ([string]$match.tree_pin_label) -PinDirectory $harnessStateDir | Write-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[adopt] The tree MOVED while this gate was open -- the adopted verdict is VOID." -ForegroundColor Red
            try {
                Update-LedgerRow -RunId ([string]$match.run_id) -Changes @{ status = 'adopted-void'; ended = (Get-UtcTimestamp); adopted = $true }
            } catch { }
            # `blocked` outranks a void tree, exactly as on the main path. Exiting 69 first meant an
            # orphaned run that reported BLOCK *and* whose tree moved came back 69, and the caller
            # never learned it was blocked. Same contract, two implementations -- and they disagreed.
            if ($adoptStatus -eq 'blocked') {
                Write-Host "[adopt] BLOCKED (and the tree also moved). Do NOT commit." -ForegroundColor Red
                exit 67
            }
            exit 69
        }
    }

    $adoptFinal = $adoptStatus
    if ($adoptScopeExit -ne 0) { $adoptFinal = "$adoptStatus+scope$adoptScopeExit" }
    try {
        Update-LedgerRow -RunId ([string]$match.run_id) -Changes @{
            status = "adopted-$adoptFinal"; ended = (Get-UtcTimestamp)
            scopeViolation = ($adoptScopeExit -ne 0); scope_exit = $adoptScopeExit
        }
    } catch { Write-Host "[adopt] WARNING: could not close the ledger row: $($_.Exception.Message)" -ForegroundColor Yellow }

    Write-Host "[adopt] reported status: $adoptStatus" -ForegroundColor DarkGray
    if ($adoptStatus -eq 'blocked') {
        Write-Host "[adopt] BLOCKED: do not commit this, and do not build on top of it." -ForegroundColor Red
        exit 67
    }
    if ($adoptScopeExit -eq 66) { exit 66 }
    if ($adoptScopeExit -ne 0) { exit 65 }
    if ($adoptStatus -eq 'done_with_concerns') { exit 68 }
    exit 0
}

if ($Adopt) {
    Invoke-Adopt
}

foreach ($required in @{
        Spec = $Spec; Task = $Task; Worktree = $Worktree; BaseSha = $BaseSha; Phase = $Phase; Prompt = $Prompt
    }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "-$($required.Key) is required unless -Adopt is used."
    }
}

if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    throw "Worktree does not exist: $Worktree"
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Codex completion schema does not exist: $schemaPath"
}

# --- ONE CODER PER WORKING TREE ---------------------------------------------------------------
# Two Codex workers in one tree is not "parallelism", it is a data race with a delete in it. Their
# writes interleave, and the first one to FINISH runs a scope check that cannot tell the other's
# in-progress files from its own out-of-scope writes -- so it reverts them. Untracked files, deleted
# outright, no git object, unrecoverable.
#
# Live: al-7c-quiet-gate (2026-07-14). Task 4 and Task 5 shared a tree; Task 4 finished first and
# DELETED Task 5's freshly-written files while Task 5 was still running and verifying against them.
# The scope check now refuses to revert while a sibling is live (exit 70) -- but that is the airbag.
# This is the seatbelt: don't have the collision.
#
# Wave-parallel dispatch (ADR-028) is still correct -- it just requires ONE WORKTREE PER CONCURRENT
# TASK (`git worktree add`), which is what -Worktree is for. Same repo path for two live tasks is
# the bug, and it is refused here rather than trusted to a rule someone has to remember.
#
# The scan and the ledger reservation are ONE ATOMIC OPERATION, under the same named mutex the
# ledger already uses. Scanning and then writing as two steps is a race in its own right: two
# dispatches can both complete the scan before either records a row, and both then launch into the
# tree the check was supposed to keep exclusive.
if (($Phase -eq 'review' -or $Schema -eq 'review' -or $Schema -eq 'endgate') -and $Sandbox -ne 'read-only') {
    # A review/end-gate must not be able to EDIT the tree it is judging. Making the caller remember
    # -Sandbox read-only is exactly the kind of instruction this harness keeps learning not to trust:
    # the standing end-gate ran with repo write access for months despite a runbook promising it
    # "never auto-edits anything". Force it.
    Write-Host "[dispatch] -Phase/-Schema '$Phase/$Schema' forces -Sandbox read-only (a reviewer must not edit what it judges)." -ForegroundColor DarkGray
    $Sandbox = 'read-only'
}

$worktreeKey = Get-WorktreeKey $Worktree

# Logs and pins are keyed by WORKTREE as well as spec/task. Concurrent dispatches in different
# worktrees are not just allowed, they are the prescribed way to run a wave -- and they were sharing
# one log file: the second dispatch truncated the first, and each watchdog watched the other's
# LastWriteTime, so a genuinely silent run could be kept "alive" by its sibling's output.
$wtSha = [System.Security.Cryptography.SHA256]::Create()
try {
    $worktreeTag = [System.BitConverter]::ToString(
        $wtSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($worktreeKey))).Replace('-', '').Substring(0, 8).ToLower()
} finally { $wtSha.Dispose() }

# The dispatch log lives OUTSIDE the worktree, beside the ledger.
#
# It used to be written into the target repo (`<worktree>/docs/progress/codex-<spec>-<task>.log`),
# which forced the scope check to exempt its own state directory -- and every version of that
# exemption was a hole (a raw prefix match let `docs/progress-evil.md` through; a collapsed untracked
# `docs/` exempted the entire tree). When the exemption was finally deleted, this log became the bug:
# the wrapper creates it, snapshots the tree, then streams Codex's output INTO it -- so at check time
# the harness's own log reads as an unauthorized write and EVERY CLEAN BUILD EXITS 65.
#
# Worse, it was created BEFORE the sibling reservation, so a dispatch that got refused (71) had
# already mutated the tree -- and, with the same spec/task, truncated the LIVE run's log.
#
# The rule that keeps falling out of all of this: THE HARNESS MUST NOT WRITE INTO THE TREE IT IS
# JUDGING. Not a snapshot, not a log, not a pin. Then there is nothing to excuse, and no excuse to
# leak through. (Found by cross-family review; my own tests hid it, because the one test that would
# have caught the spurious 65 was already expecting a 65 for a different reason.)
$logDirectory = Join-Path $ledgerDirectory 'codex-logs'
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
Assert-NotInsideRepo -Path $ScratchDirectory -What 'The -ScratchDirectory (which holds the .final report)'
[System.IO.Directory]::CreateDirectory($ScratchDirectory) | Out-Null
$safeSpec = ConvertTo-SafeFileName $Spec
$safeTask = ConvertTo-SafeFileName $Task
$logPath = Join-Path $logDirectory "codex-$safeSpec-$safeTask-$($worktreeTag).log"

[System.IO.File]::WriteAllText($logPath, [string]::Empty, [System.Text.UTF8Encoding]::new($false))

$runId = [guid]::NewGuid().ToString('N')
# The key under which this run's GATE EVIDENCE is filed. It carries the run id, so no two runs can
# ever read or overwrite each other's snapshot or pin -- however their spec/task names collapse.
$gateKey = "$safeSpec-$safeTask-$($runId.Substring(0,8))"

# The report path is UNIQUE PER RUN, and that is load-bearing.
#
# It used to be "codex-$safeSpec-$safeTask.final" in a shared scratch dir, which is wrong three ways:
#   * COLLISION. spec=a-b/task=c and spec=a/task=b-c both produce codex-a-b-c.final, and
#     ConvertTo-SafeFileName's lossy substitution adds more. Two runs, one filename.
#   * DESTRUCTION. To stop a crashed run being judged on the LAST run's verdict, the previous
#     version DELETED any pre-existing report at launch -- so a run starting in one worktree could
#     delete the live report of a run in ANOTHER worktree. And this change set now actively
#     ENCOURAGES concurrent worktrees. I built a footgun and then handed out more guns.
#   * The stale-report bug it was patching only exists BECAUSE the path was reused.
# A unique path kills all three: no collision, nothing to delete, and a missing report can only ever
# mean THIS run produced no verdict.
$finalPath = Join-Path $ScratchDirectory "codex-$safeSpec-$safeTask-$($runId.Substring(0,8)).final"

$started = Get-UtcTimestamp
$ledgerRow = [ordered]@{
    run_id = $runId
    pid = $null
    # The LAUNCHER's pid, recorded BEFORE the child exists. Between Add-LedgerRow and the moment the
    # child's pid is known, `pid` is null -- and a sibling scanning in that window would see no live
    # process and conclude the tree was free, then revert the very files this run is about to write.
    # The launcher is alive for the whole dispatch, so it closes that window.
    launcher_pid = $PID
    launcher_start = (Get-ProcessStamp $PID)
    pid_start = $null
    worktree = $Worktree
    worktree_key = $worktreeKey   # canonical: git's repo root, not the caller's spelling of the path
    spec = $Spec
    task = $Task
    base_sha = $BaseSha
    phase = $Phase
    started = $started
    log_path = $logPath
    final_path = $finalPath
    schema = $schemaFile
    sandbox = $Sandbox
    # What this run ARMED, so -Adopt can run the gates the dead wrapper never reached.
    scope_armed = ($Authorized.Count -gt 0 -and -not $SkipScopeCheck)
    scope_task = $gateKey
    authorized = @($Authorized)
    tree_pin_label = $null
    status = 'running'
}

# --- ONE CODER PER WORKING TREE: scan and reserve, ATOMICALLY ----------------------------------
# Two Codex workers in one tree is not "parallelism", it is a data race with a delete in it. Their
# writes interleave, and the first one to FINISH runs a scope check that cannot tell the other's
# in-progress files from its own out-of-scope writes -- so it reverts them. Untracked files, deleted
# outright, no git object, unrecoverable. Live: al-7c-quiet-gate (2026-07-14), where Task 4 deleted
# Task 5's freshly-written files while Task 5 was still running. The scope check now refuses to
# revert while a sibling is live (exit 70) -- that is the airbag. This is the seatbelt.
#
# Scan-then-write as two steps is itself a race: both dispatches finish the scan before either
# records a row, and both launch. So the scan and the reservation happen inside ONE hold of the
# ledger mutex -- the check is only as exclusive as the write that follows it.
#
# Wave-parallel dispatch (ADR-028) is still correct. It just requires ONE WORKTREE PER CONCURRENT
# TASK (`git worktree add`), which is what -Worktree is for.
$refused = $null
Invoke-WithLedgerLock {
    $liveHere = @(Get-LiveDispatches -WorktreeKey $worktreeKey)
    if ($liveHere.Count -gt 0 -and -not $AllowSharedWorktree) {
        $script:refused = $liveHere
        return
    }
    [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
    [System.IO.File]::AppendAllText(
        $ledgerPath,
        ($ledgerRow | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

if ($refused) {
    Write-Host ''
    Write-Host "[dispatch] REFUSING TO LAUNCH - a Codex worker is already running in this working tree:" -ForegroundColor Red
    foreach ($l in $refused) { Write-Host ("      {0}/{1}  pid {2}  status {3}" -f $l.spec, $l.task, $l.pid, $l.status) -ForegroundColor Red }
    Write-Host "[dispatch] Two coders in one tree is a data race with a DELETE in it: whichever finishes first" -ForegroundColor Red
    Write-Host "[dispatch] runs a scope check that cannot tell the other's in-progress files from its own" -ForegroundColor Red
    Write-Host "[dispatch] out-of-scope writes, and reverts them. That destroyed real work on 2026-07-14." -ForegroundColor Red
    Write-Host ''
    Write-Host "[dispatch] Give each concurrent task its OWN worktree:" -ForegroundColor Yellow
    Write-Host "[dispatch]     git worktree add ../wt-$safeTask $BaseSha" -ForegroundColor Yellow
    Write-Host "[dispatch] then pass it as -Worktree. Or dispatch serially. -AllowSharedWorktree overrides." -ForegroundColor Yellow
    Write-Host ''
    exit 71
}

# --- Host-side scope enforcement (snapshot) -------------------------------------------------------
# The prose scope lock below is NOT the enforcement. It is a courtesy. Codex has been given that
# rule, in those words, and has written outside its scope anyway -- prohibitions do not enforce.
# The mechanism is codex-scope-check.ps1: snapshot the dirty set BEFORE launch, diff it AFTER exit,
# revert anything unauthorized that was clean at snapshot time. Wiring it into the dispatcher --
# rather than documenting it as a step for the host to remember -- is the whole point. A procedure a
# human has to remember is the procedure that gets skipped at 2am.
$scopeCheckScript = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$scopeCheckArmed = $false
if ($Authorized.Count -gt 0) {
    if (-not (Test-Path $scopeCheckScript)) {
        # A gate that quietly disappears when its file is missing is not a gate. The caller ASKED for
        # scope enforcement; running the build without it and reporting success is the worst possible
        # answer. Refuse.
        Update-LedgerRow -RunId $runId -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = 'codex-scope-check.ps1 missing' }
        throw "-Authorized was given but codex-scope-check.ps1 is missing ($scopeCheckScript). Refusing to dispatch without the enforcement that was asked for."
    }
    else {
        & $scopeCheckScript -Snapshot -Worktree $Worktree -Task $gateKey -StateDirectory $harnessStateDir | Write-Host
        $scopeCheckArmed = $true
    }
}
elseif (-not $SkipScopeCheck) {
    Write-Host "[dispatch] NOTE: no -Authorized file list given, so the scope lock is prose only and unenforced." -ForegroundColor Yellow
    Write-Host "[dispatch]       Pass -Authorized with the spec's '## Files to change' list to enforce it, or -SkipScopeCheck to silence this." -ForegroundColor Yellow
}

# --- Tree pin: WIRED IN, not written down ------------------------------------------------------
# A read-only gate (a review, an end-gate) reads the tree at time T and returns a verdict at T+n.
# If the tree moves in between, the verdict describes a tree that no longer exists -- and the
# dangerous direction is a CLEAN verdict on code that nobody actually reviewed.
#
# tree-pin.ps1 was written for exactly this and then WIRED INTO NOTHING: it lived only as a step in
# apex-code's SKILL.md for the host to remember. That is precisely the mistake this session spent
# the whole day correcting in everything else -- "mechanism beats instruction, including when you
# are the one writing the instruction" -- committed by the person writing that sentence. Caught by
# the cross-family review, which is the entire reason an agent does not review its own work.
$treePinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
$treePinLabel = $gateKey
$treePinArmed = $false
if ((-not $NoTreePin) -and ($Sandbox -eq 'read-only' -or $Phase -eq 'review') -and -not (Test-Path $treePinScript)) {
    Update-LedgerRow -RunId $runId -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = 'tree-pin.ps1 missing' }
    throw "A read-only gate must be pinned, but tree-pin.ps1 is missing ($treePinScript). Refusing: an unpinned gate can bless a tree that moved under it. Pass -NoTreePin to opt out deliberately."
}
if ((-not $NoTreePin) -and ($Sandbox -eq 'read-only' -or $Phase -eq 'review') -and (Test-Path $treePinScript)) {
    & $treePinScript -Pin -Worktree $Worktree -Label $treePinLabel -PinDirectory $harnessStateDir | Write-Host
    $treePinArmed = ($LASTEXITCODE -eq 0)
    if ($treePinArmed) {
        try { Update-LedgerRow -RunId $runId -Changes @{ tree_pin_label = $treePinLabel } } catch { }
    }
}

# Standing scope lock, appended to EVERY dispatch. Belt-and-braces only -- see above.
# A planning host commonly edits docs/status.md in the same working tree while a build runs; Codex
# has repeatedly rewritten it out of scope-lock, and a blanket revert of it has already destroyed
# concurrent owner planning work once.
$scopeLock = @'

---
STANDING SCOPE LOCK (applies to every dispatch; overrides anything above that conflicts):
- Do NOT read, write, edit, or create docs/status.md. It is owned by the planning host, who is very
  likely editing it RIGHT NOW in this same working tree. Any write you make to it destroys their
  work. If you believe it needs updating, say so in your final report instead.
- Do NOT edit any file outside the scope this dispatch named. That includes other specs under
  docs/changes/, other runbooks, and any doc you were not explicitly asked to change.
- Do NOT run `git commit`, `git add`, `git push`, `git checkout --`, `git reset`, or `git stash`.
  The host integrates and commits; you only leave changes in the working tree.
'@
$Prompt = $Prompt + $scopeLock



$arguments = @(
    'exec', '-p', 'apex-coder', '--sandbox', $Sandbox, '-m', 'gpt-5.6-sol',
    '-c', "model_reasoning_effort=$Effort", '-C', $Worktree, '--json', '--output-schema',
    $schemaPath, '-o', $finalPath, '--color', 'never'
) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }

# ProcessStartInfo uses CreateProcess rather than PowerShell command resolution.
# The npm installation exposes `codex` to PowerShell as codex.ps1; invoke its
# node entry point directly because a .cmd shim is not executable with
# UseShellExecute = $false.
# Everything from here on can throw, and the ledger row already says `running`. A throw between the
# reservation and the main try left that row `running` FOREVER -- and a permanently-live phantom row
# makes every future dispatch into this worktree exit 71, wedging the harness until someone edits the
# ledger by hand. (I claimed this was fixed in a review pack before writing it; it was not.)
try {
    $resolvedCodexExecutable = $CodexExecutable
    $prefixArguments = @($CodexExecutableArgumentPrefix | ForEach-Object {
            ConvertTo-ProcessArgument ([string]$_)
        })
    $resolvedArguments = $prefixArguments + $arguments
    if ($CodexExecutable -eq 'codex') {
        $codexCommand = @(Get-Command codex -CommandType Application, ExternalScript -ErrorAction Stop)[0]
        if ($codexCommand.CommandType -eq 'ExternalScript') {
            $npmBinDirectory = Split-Path $codexCommand.Source -Parent
            $nodePath = Join-Path $npmBinDirectory 'node.exe'
            $codexEntryPoint = Join-Path $npmBinDirectory 'node_modules\@openai\codex\bin\codex.js'
            if (-not (Test-Path -LiteralPath $codexEntryPoint -PathType Leaf)) {
                throw "The PowerShell Codex command has no node entry point: $codexEntryPoint"
            }
            $resolvedCodexExecutable = if (Test-Path -LiteralPath $nodePath -PathType Leaf) { $nodePath } else { 'node' }
            $resolvedArguments = @((ConvertTo-ProcessArgument $codexEntryPoint)) + $prefixArguments + $arguments
        } else {
            $resolvedCodexExecutable = $codexCommand.Source
        }
    }
} catch {
    Update-LedgerRow -RunId $runId -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = $_.Exception.Message }
    throw
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedCodexExecutable
$startInfo.Arguments = [string]::Join(' ', [string[]]$resolvedArguments)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$appendLogText = {
    param([string]$Text)
    if ($Text.Length -gt 0) {
        [System.IO.File]::AppendAllText($logPath, $Text, [System.Text.UTF8Encoding]::new($false))
    }
}

try {
    if (-not $process.Start()) { throw 'Failed to start codex exec.' }

    # ADR-033's load-bearing behavior: write the whole dispatch pack and close
    # the redirected stdin immediately, so Codex never inherits a wedged stdin.
    $process.StandardInput.Write($Prompt)
    $process.StandardInput.Close()
    Update-LedgerRow -RunId $runId -Changes @{ pid = $process.Id; pid_start = (Get-ProcessStamp $process.Id) }

    # Read both redirected streams asynchronously without PowerShell event
    # handlers.  Windows PowerShell invokes those handlers on threads without a
    # runspace, while these .NET tasks keep the JSON log live for the watchdog.
    $bufferSize = 4096
    $stdoutBuffer = New-Object char[] $bufferSize
    $stderrBuffer = New-Object char[] $bufferSize
    $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
    $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
    $stdoutClosed = $false
    $stderrClosed = $false
    $stalled = $false
    $nextWatchCheck = (Get-Date).AddSeconds(15)
    while (-not $process.HasExited) {
        if ($stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if ($stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }

        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { break }

        if ((Get-Date) -ge $nextWatchCheck) {
            $lastWrite = (Get-Item -LiteralPath $logPath).LastWriteTime
            if (((Get-Date) - $lastWrite).TotalMinutes -ge $NoOutputTimeoutMin) {
                Update-LedgerRow -RunId $runId -Changes @{ status = 'stalled'; stalled = (Get-UtcTimestamp) }
                $stalled = $true
                break
            }
            $nextWatchCheck = (Get-Date).AddSeconds(15)
        }
    }

    if ($stalled) {
        # Do not kill the child: the caller owns that decision.
        exit 124
    }

    $process.WaitForExit()
    while (-not ($stdoutClosed -and $stderrClosed)) {
        if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if (-not $stderrClosed -and $stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }
        if (-not ($stdoutClosed -and $stderrClosed)) { Start-Sleep -Milliseconds 25 }
    }
    $exitCode = $process.ExitCode
    $status = if ($exitCode -eq 0) { 'done' } else { 'failed' }

    # --- The completion report is the verdict; the exit code is not -------------------------------
    # Codex exits 0 even when its own report says `blocked`. A dispatcher that reads the exit code
    # reads "success" -- so the host commits code the coder never inspected, formatted, linted, or
    # tested, and then builds the next spec on top of it. That is exactly what happened to
    # cap-deps-1b (2026-07-14): exit 0, `.final` said `"status": "blocked"`, and the blocker was
    # "the sandbox can no longer launch helpers, so implementation cannot be inspected, corrected,
    # or verified". Nobody read it. Read `.final` (what -o captures) -- never the log, never the
    # exit code alone.
    $reportStatus = $null
    $unresolved = @()
    $deviations = @()
    $blocker = $null
    $reviewVerdict = $null
    if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
        try {
            $report = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
            $reportStatus = [string]$report.status

            # A REVIEW report has no `status` -- it has `verdict` (BLOCK / FLAG / CLEAN), and its
            # findings live in `findings`. Reading only `status` left it empty, so $status stayed
            # 'done' and the dispatcher EXITED 0 ON A BLOCKING REVIEW.
            #
            # This is not hypothetical: the two cross-family reviews of this very harness both
            # returned BLOCK and both exited 0. The only reason the findings were acted on is that
            # the host read the report by hand. A mechanism built to stop people trusting exit codes
            # was itself trusting an exit code. (Found by the second of those reviews.)
            if ($report.PSObject.Properties.Name -contains 'verdict') {
                $reviewVerdict = [string]$report.verdict
                # Count only findings that ACTUALLY flag something. codex-review.md tells a clean
                # reviewer to return a single CLEAN finding -- counting that as a concern made exit 0
                # unreachable for a reviewer following its own instructions, which trains everyone to
                # ignore 68.
                $findingCount = 0
                if ($report.findings) {
                    $findingCount = @($report.findings | Where-Object {
                        $sev = ([string]$_.severity).ToUpperInvariant()
                        $sev -and $sev -ne 'CLEAN' -and $sev -ne 'NONE' -and $sev -ne 'INFO'
                    }).Count
                }
                $v = $reviewVerdict.ToUpperInvariant()

                # FAIL CLOSED on anything not recognisably clean.
                #
                # The first version had `default { $reportStatus = 'done' }` -- so an unrecognised
                # verdict, a lowercase one, a missing one, or an end-gate returning
                # `"verdict": "P1: block handoff"` all came back as SUCCESS. A gate whose unknown
                # states mean "pass" is not a gate. And any findings at all mean there is something
                # to read, whatever the verdict string says.
                # A BLOCK-severity FINDING outranks a cheerful verdict string. Adoption already did
                # this; the main path only counted findings without looking at their severity -- so a
                # report saying `verdict: CLEAN` while carrying a BLOCK finding exited 68 instead of
                # 67. Two copies of one rule, and the weaker copy fails open. Again.
                $hasBlockingFinding = $false
                if ($report.findings) {
                    $hasBlockingFinding = @($report.findings | Where-Object {
                        ([string]$_.severity).ToUpperInvariant() -like '*BLOCK*'
                    }).Count -gt 0
                }

                if ($v -like '*BLOCK*' -or $hasBlockingFinding) {
                    $reportStatus = 'blocked'
                    $blocker = "Review verdict '$reviewVerdict' -- $findingCount finding(s), at least one BLOCK. Read them; do not commit."
                } elseif ($v -like '*FLAG*' -or $v -like 'P1*' -or $v -like 'P2*') {
                    $reportStatus = 'done_with_concerns'
                    $unresolved += "Review verdict '$reviewVerdict' -- $findingCount finding(s) to adjudicate."
                } elseif ($v -eq 'CLEAN' -or $v -eq 'PASS' -or $v -eq 'OK') {
                    if ($findingCount -gt 0) {
                        $reportStatus = 'done_with_concerns'
                        $unresolved += "Verdict says '$reviewVerdict' but $findingCount finding(s) were returned. Read them."
                    } elseif (-not $reportStatus) { $reportStatus = 'done' }
                } else {
                    $reportStatus = 'blocked'
                    $blocker = "Unrecognised review verdict '$reviewVerdict' ($findingCount finding(s)). Failing closed: an unknown gate state is not a pass."
                }
            }
            elseif ($Schema -ne 'completion' -and -not $reportStatus) {
                # A review/end-gate schema report with NO verdict and NO status says nothing at all.
                $reportStatus = 'blocked'
                $blocker = 'The review report carried neither a verdict nor a status. A gate that said nothing did not pass.'
            }

            if ($report.unresolved) { $unresolved += @($report.unresolved) }
            if ($report.deviations) { $deviations = @($report.deviations) }
            if ($report.blocker) { $blocker = [string]$report.blocker }

            # The schema does not COUPLE `status` to `blocker`/`unresolved`, so a careless coder can
            # return `status: done` while also naming a blocker ("tests could not run") and listing
            # unresolved work. The wrapper printed those and exited 0 -- which is exactly the
            # cap-deps-1b failure wearing a different field. The status is the coder's CLAIM; the
            # blocker and the unresolved list are its EVIDENCE. Believe the evidence.
            if ($blocker -and $reportStatus -eq 'done') {
                $reportStatus = 'blocked'
            }
            elseif ($unresolved.Count -gt 0 -and $reportStatus -eq 'done') {
                $reportStatus = 'done_with_concerns'
            }
        } catch {
            $reportStatus = 'blocked'
            $blocker = "Unparseable completion report: $($_.Exception.Message)"
        }
    } elseif ($exitCode -eq 0) {
        # Exit 0 with no report is not a success. It is a dispatch that produced no verdict, and a
        # missing verdict must never read as a passing one.
        $reportStatus = 'blocked'
        $blocker = 'Codex exited 0 without writing a completion report.'
    }

    # `done_with_concerns` with an empty `unresolved` is self-contradictory: the status word says
    # there are concerns, the payload says there are none. Believe the status word.
    if ($reportStatus -eq 'done_with_concerns' -and $unresolved.Count -eq 0) {
        $unresolved = @('Coder reported done_with_concerns but named no unresolved items. Treat this build as unverified.')
    }

    if ($reportStatus -eq 'blocked') { $status = 'blocked' }
    elseif ($reportStatus -eq 'done_with_concerns' -and $status -eq 'done') { $status = 'done_with_concerns' }

    # --- Host-side scope enforcement (check) ------------------------------------------------------
    # Runs on EVERY exit path, including a failed task -- a task that failed may still have written
    # files it was never authorized to touch, and those are exactly the ones nobody goes looking for.
    # The scope result is its OWN axis. It must never overwrite the coder's verdict.
    #
    # The first version assigned $status = 'scope-violation' on ANY non-zero scope exit -- which
    # silently destroyed the `blocked` hard stop, the headline fix of this whole change set: a coder
    # reporting `blocked` plus any scope result exited 65 instead of 67, so the host read
    # "scope violation, reverted" and committed code the coder never verified. It also announced
    # "out-of-scope paths were reverted" for exit 70 and 72, where NOTHING was reverted.
    #
    # Two independent facts (did the coder finish? did it stay in scope?) need two variables.
    $scopeViolation = $false
    $scopeExit = 0
    if ($scopeCheckArmed) {
        & $scopeCheckScript -Check -Worktree $Worktree -Task $gateKey -Authorized $Authorized -ExcludeRunId $runId -StateDirectory $harnessStateDir | Write-Host
        $scopeExit = $LASTEXITCODE
        if ($scopeExit -ne 0) { $scopeViolation = $true }

        # The scope check DETECTS; it never reverts (it destroyed real work twice when it did, by
        # inferring authorship from timing while other writers were live). So nothing here may claim
        # anything was cleaned up: the out-of-scope changes are still in the tree, for a human.
        switch ($scopeExit) {
            0 { }
            66 {
                Write-Host "[dispatch] The -Authorized list looks wrong, not the coder. See above." -ForegroundColor Red
            }
            default {
                Write-Host "[dispatch] Task '$Task' wrote OUTSIDE its authorized set. Nothing was reverted - the changes" -ForegroundColor Red
                Write-Host "[dispatch] are still in the tree. Usually a SPEC DEFECT: the task needed a file its spec did" -ForegroundColor Red
                Write-Host "[dispatch] not list. Surface it to planning; do not just re-run." -ForegroundColor Red
            }
        }
    }

    # Did the tree move while this read-only gate was open? If so the verdict is about a tree that no
    # longer exists, and a CLEAN verdict would be a rubber stamp on unreviewed code.
    $treeMoved = $false
    if ($treePinArmed) {
        & $treePinScript -Verify -Worktree $Worktree -Label $treePinLabel -PinDirectory $harnessStateDir | Write-Host
        if ($LASTEXITCODE -ne 0) { $treeMoved = $true }
    }

    Update-LedgerRow -RunId $runId -Changes @{
        status = $status; ended = (Get-UtcTimestamp)
        scopeViolation = $scopeViolation; scope_exit = $scopeExit; tree_moved = $treeMoved
        report_status = $reportStatus; unresolved = $unresolved; deviations = $deviations; blocker = $blocker
    }

    # The coder's own account of what it could not finish is the single highest-value input to the
    # review that follows -- and it is exactly what got dropped on cap-deps-1b, leaving the reviewer
    # to re-derive the coder's doubts from scratch. Print it where the host cannot miss it, and
    # leave it on disk next to the report so the review dispatch can paste it in verbatim.
    if ($unresolved.Count -gt 0 -or $deviations.Count -gt 0 -or $blocker) {
        $concernsPath = "$finalPath.concerns.md"
        $concernsLines = @("# Coder-reported concerns -- $Spec / $Task", '', "Reported status: **$reportStatus**", '')
        if ($blocker) { $concernsLines += @('## Blocker', '', $blocker, '') }
        if ($unresolved.Count -gt 0) { $concernsLines += @('## Unresolved', '') + ($unresolved | ForEach-Object { "- $_" }) + @('') }
        if ($deviations.Count -gt 0) { $concernsLines += @('## Deviations', '') + ($deviations | ForEach-Object { "- $_" }) + @('') }
        [System.IO.File]::WriteAllLines($concernsPath, [string[]]$concernsLines, [System.Text.UTF8Encoding]::new($false))

        Write-Host ''
        Write-Host "[dispatch] The coder reported '$reportStatus'. Its own words -- carry these into the review:" -ForegroundColor Yellow
        if ($blocker) { Write-Host "[dispatch]   BLOCKER: $blocker" -ForegroundColor Red }
        foreach ($item in $unresolved) { Write-Host "[dispatch]   UNRESOLVED: $item" -ForegroundColor Yellow }
        foreach ($item in $deviations) { Write-Host "[dispatch]   DEVIATION:  $item" -ForegroundColor Yellow }
        Write-Host "[dispatch]   -> $concernsPath" -ForegroundColor Yellow
        Write-Host ''
    }

    Write-Host "[dispatch] report: $finalPath" -ForegroundColor DarkGray

    # `blocked` outranks EVERYTHING, including a moved tree. The contract says so, and the previous
    # ordering contradicted it: a blocked report plus any tree movement exited 69 and never reached
    # the 67 branch, so the hard stop was lost to the void. A void verdict still means "do not act";
    # a blocked coder means "do not commit" -- and the second is the one that ships bad code.
    if ($status -eq 'blocked') {
        Write-Host "[dispatch] BLOCKED: the coder did not complete this task. Do NOT commit and do NOT build on top of it." -ForegroundColor Red
        Write-Host "[dispatch] Clear every unresolved item with a host re-verify first." -ForegroundColor Red
        if ($treeMoved) { Write-Host "[dispatch] (The tree ALSO moved under this gate. Both are true; blocked is the worse one.)" -ForegroundColor Red }
        if ($scopeViolation) { Write-Host "[dispatch] (Also flagged out-of-scope writes: scope-check exit $scopeExit. Nothing was reverted.)" -ForegroundColor Red }
        exit 67
    }

    if ($treeMoved) {
        Write-Host "[dispatch] THE TREE MOVED while this gate was open. The verdict is VOID -- do not act on it." -ForegroundColor Red
        Write-Host "[dispatch] Find the writer (a live coder, a concurrent agent, a hand-edit), let it finish, re-run the gate." -ForegroundColor Red
        exit 69
    }

    # EXIT PRECEDENCE, most severe first. Each of these is an independent fact, and the exit code can
    # only carry one -- so the most dangerous one to ignore wins, and the rest are printed above and
    # recorded in the ledger. `blocked` outranks everything: a coder saying "I could not verify, or
    # even re-read, what I wrote" is worse news than where it wrote it.
    # The -Authorized list being wrong is a DIFFERENT failure from the coder wandering out of scope,
    # and the host must route it differently (fix the spec, not the coder). Collapsing it into 65 made
    # the documented 66 unreachable.
    if ($scopeExit -eq 66) { exit 66 }

    # A scope violation is a real failure WHATEVER the child's exit code was. Gating this on
    # `$exitCode -eq 0` meant a child that wrote out of scope AND exited 2 passed exit 2 straight
    # through -- outside the documented exit space entirely, and with the scope route hidden. A child
    # failure does not excuse an out-of-scope write; it is usually how you get one.
    if ($scopeViolation) { exit 65 }

    # `done_with_concerns` is not `done`. It exits distinctly so the host must decide, not skim.
    if ($status -eq 'done_with_concerns') { exit 68 }

    # A CHILD's exit code must never be passed through into the wrapper's RESERVED space. Codex
    # exiting 67 (for its own reasons) is not "the coder reported blocked"; a caller reading the
    # contract would act on a verdict that was never given. Remap anything that collides.
    # The wrapper's exit space is a CONTRACT: 0/1/65/66/67/68/69/71/75/124. Passing an arbitrary child
    # code straight through breaks it -- a child exiting 2 told the caller nothing the contract can
    # express, and a child exiting 67 claimed a `blocked` verdict it never gave.
    if ($exitCode -ne 0) {
        Write-Host "[dispatch] child failed (exit $exitCode); reporting 1 (child failure)." -ForegroundColor Yellow
        exit 1
    }
    exit 0
} catch {
    # A launch/setup failure has no child exit code, but it is still durable.
    Update-LedgerRow -RunId $runId -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = $_.Exception.Message }
    throw
} finally {
    $process.Dispose()
    $ledgerMutex.Dispose()
}
