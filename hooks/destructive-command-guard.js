#!/usr/bin/env node
/**
 * PreToolUse Hook: Destructive-Command Hard-Block
 *
 * Hard-blocks never-list destructive commands, data exfiltration, and remote-code-execution
 * (pipe-to-shell) patterns. Contract: reads PreToolUse JSON from stdin; writes a deny decision
 * to stdout on match; exits 0 either way.
 *
 * ── 2026-07-14 (ADR-038) ──────────────────────────────────────────────────────────────────────
 * This guard used to run ONLY in "coding mode":
 *
 *     var codingMode = baseUrl.indexOf('deepseek') >= 0 || process.env.APEX_MODE === 'coding';
 *     if (!codingMode) return null;
 *
 * ADR-038 removed the mode split, so APEX_MODE is never set — which silently DISARMED this guard
 * entirely. `rm -rf` was allowed. The gate is gone: **the guard now runs in every session**, which
 * is correct regardless, because every session can now build.
 *
 * Two checks were also wired in that had been written but never reachable: isExfiltrationBash and
 * isRemoteCodeExec. They came out of two rounds of apex-security BLOCK findings ("no exfil check",
 * "pipe-to-shell RCE") but were only ever called from the AFK allowlist (isSafeAfkBash), which was
 * itself removed with the !afk gate. They were dead code enforcing nothing. They now enforce.
 * ──────────────────────────────────────────────────────────────────────────────────────────────
 */

'use strict';

var detection = require('./lib/destructive-detect');
var resolveDisable = require('./lib/guard-disable');
var isDestructiveBash = detection.isDestructiveBash;
var isReadOnlyGitIntrospection = detection.isReadOnlyGitIntrospection;
var isExfiltrationBash = detection.isExfiltrationBash;
var isRemoteCodeExec = detection.isRemoteCodeExec;

var input = '';
var timeoutSetting = String(process.env.APEX_GUARD_STDIN_TIMEOUT_MS || '').trim();
var parsedTimeout = Number(timeoutSetting);
var stdinTimeoutMs = /^[1-9][0-9]*$/.test(timeoutSetting) && Number.isSafeInteger(parsedTimeout)
  ? parsedTimeout
  : 3000;
var finished = false;
var stdinTimeout = setTimeout(function() {
  finish(deny('The destructive-command guard timed out while reading tool input and failed closed.'));
}, stdinTimeoutMs);
process.stdin.setEncoding('utf8');
process.stdin.on('data', function(chunk) { input += chunk; });
process.stdin.on('error', function() {
  finish(deny('The destructive-command guard could not read tool input and failed closed.'));
});
process.stdin.on('end', function() {
  if (finished) return;
  clearTimeout(stdinTimeout);

  try {
    var data = JSON.parse(input);
    finish(handlePreToolUse(data));
  } catch (_) {
    finish(deny('The destructive-command guard could not validate the tool input and failed closed.'));
  }
});

function finish(result) {
  if (finished) return;
  finished = true;
  clearTimeout(stdinTimeout);
  if (result) {
    process.stdout.write(JSON.stringify(result), function() { process.exit(0); });
    return;
  }
  process.exit(0);
}

function deny(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason +
        ' To run it deliberately, restart with APEX_DESTRUCT_GUARD=off and set ' +
        'APEX_GUARD_DISABLE_REASON; the disable takes effect only when its audit entry is written.'
    }
  };
}

function handlePreToolUse(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return deny('The destructive-command guard received malformed tool input and failed closed.');
  }
  if (!data.tool_input || typeof data.tool_input !== 'object' || Array.isArray(data.tool_input)) {
    return deny('The destructive-command guard received malformed tool input and failed closed.');
  }

  var hasCommand = Object.prototype.hasOwnProperty.call(data.tool_input, 'command');
  var command = data.tool_input.command;
  if (hasCommand && typeof command !== 'string') {
    return deny('The destructive-command guard received a non-string command and failed closed.');
  }
  if (!command) {
    return null;
  }

  if (data.tool_name !== 'Bash' && data.tool_name !== 'PowerShell') {
    return null;
  }

  var disable = resolveDisable({
    guard: 'destructive-command-guard',
    disableValue: process.env.APEX_DESTRUCT_GUARD,
    reason: process.env.APEX_GUARD_DISABLE_REASON,
    subject: command
  });
  if (disable.disabled) {
    return null;
  }

  // Read-only git introspection (log/status/diff/show) is always fine — checked first so a
  // `git log -p` full of scary-looking strings can never trip the patterns below.
  if (isReadOnlyGitIntrospection(command)) {
    return null;
  }

  if (isDestructiveBash(command)) {
    return deny('This command is on the APEX destructive-command never-list and is blocked.');
  }

  if (isExfiltrationBash(command)) {
    return deny('This command looks like data exfiltration (piping local files or secrets to a remote host) and is blocked.');
  }

  if (isRemoteCodeExec(command)) {
    return deny('This command looks like remote code execution (fetching a script and piping it to a shell) and is blocked.');
  }

  return null;
}
