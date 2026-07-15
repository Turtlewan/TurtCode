# Fake `codex exec` that reproduces the STDIN/STDOUT PIPE DEADLOCK.
#
# The other fake (dispatch-test-fakecodex.ps1) does [Console]::In.ReadToEnd() FIRST and only then
# writes stdout. That ordering keeps the stdin pipe drained, so the concurrent-pipe deadlock can
# never occur -- which is exactly why the suite was blind to it for so long.
#
# Real `codex exec --json` streams events to stdout FROM LAUNCH, before (and while) it consumes
# stdin. This fake does the same: it floods stdout BEFORE it reads a byte of stdin. Against a wrapper
# that writes the whole prompt to stdin synchronously before it starts draining stdout, this
# deadlocks: the fake blocks writing stdout (nobody reading), so it never reads stdin, so the
# wrapper's synchronous stdin write never returns. Against a wrapper that services all three pipes
# concurrently, it completes.
#
# Raw $args (no param() block) for the same reason the sibling fake documents: an advanced function
# turns `-o <path>` into an ambiguous common-parameter match.
$PassThruArgs = $args

# Flood stdout BEFORE touching stdin. 200 KB is comfortably over the Windows pipe buffer, so the old
# synchronous-write wrapper is guaranteed to wedge here.
$flood = 'x' * 200000
[Console]::Out.Write($flood)
[Console]::Out.Flush()

# Only now drain stdin. A correctly-servicing wrapper has been reading our stdout concurrently, so
# this returns; a deadlocked one never lets us get here.
$prompt = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($prompt)) {
    Write-Output "FAKE-DEADLOCK: FAIL - no prompt provided via stdin"
    exit 1
}
Write-Output "FAKE-DEADLOCK: drained stdin, $($prompt.Length) chars"

# Honour -o and write a minimal completion report, so the dispatcher's report path is exercised.
$finalPath = $null
for ($i = 0; $i -lt $PassThruArgs.Count - 1; $i++) {
    if ($PassThruArgs[$i] -eq '-o') { $finalPath = $PassThruArgs[$i + 1]; break }
}
if ($finalPath) {
    $report = [ordered]@{
        status        = 'done'
        changed_files = @()
        commands_run  = @(@{ command = 'noop'; result = 'pass'; detail = $null })
        deviations    = @()
        unresolved    = @()
        blocker       = $null
    }
    [System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
}
Write-Output "FAKE-DEADLOCK: done"
exit 0
