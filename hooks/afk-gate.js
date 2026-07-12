#!/usr/bin/env node
/**
 * PreToolUse Hook: AFK Permission Gate
 *
 * When a valid AFK flag is present, explicitly permits only safe writes and
 * allowlisted shell commands. Critical files and unlisted commands fall
 * through to the normal permission gate.
 */

'use strict';

var fs = require('fs');
var path = require('path');
var detection = require('./lib/destructive-detect');
var isDestructiveBash = detection.isDestructiveBash;
var isExfiltrationBash = detection.isExfiltrationBash;
var isRemoteCodeExec = detection.isRemoteCodeExec;
var isAfkFlagWrite = detection.isAfkFlagWrite;
var isSafeAfkBash = detection.isSafeAfkBash;
var isCriticalPathShared = detection.isCriticalPath;

var CLAUDE_HOME = 'C:\\Users\\User\\.claude';
var AFK_FLAG_PATH = path.join(CLAUDE_HOME, 'afk.on');

var input = '';
var stdinTimeout = setTimeout(function() { process.exit(0); }, 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', function(chunk) { input += chunk; });
process.stdin.on('end', function() {
  clearTimeout(stdinTimeout);

  try {
    var data = JSON.parse(input);
    var result = handlePreToolUse(data);
    if (result) {
      process.stdout.write(JSON.stringify(result));
    }
  } catch (_) {
    // Parse error or unexpected input: allow the tool call through silently.
  }

  process.exit(0);
});

function handlePreToolUse(data) {
  var toolName = data && data.tool_name;
  var toolInput = (data && data.tool_input) || {};

  // This must happen before checking whether AFK is armed.
  if ((toolName === 'Write' || toolName === 'Edit') && isAfkFlagPath(getFilePath(toolInput))) {
    return askToArm();
  }
  if (toolName === 'Bash' && isAfkFlagWrite(toolInput.command || '')) {
    return askToArm();
  }

  if (!isArmed()) {
    return null;
  }

  if (toolName === 'Write' || toolName === 'Edit') {
    var targetPath = getFilePath(toolInput);
    if (isCriticalPath(targetPath)) {
      return null;
    }
    return allow();
  }

  if (toolName === 'Bash') {
    var command = toolInput.command || '';
    if (isDestructiveBash(command) || isExfiltrationBash(command) || isRemoteCodeExec(command)) {
      return denyNeverList();
    }
    if (isSafeAfkBash(command)) {
      return allow();
    }
  }

  return null;
}

function getFilePath(toolInput) {
  return toolInput.file_path || toolInput.path || '';
}

function isArmed() {
  var contents;
  try {
    if (!fs.existsSync(AFK_FLAG_PATH)) {
      return false;
    }
    contents = fs.readFileSync(AFK_FLAG_PATH, 'utf8');
  } catch (_) {
    return false;
  }

  var token = null;
  var expires = null;
  String(contents).split(/\r?\n/).forEach(function(line) {
    var equals = line.indexOf('=');
    if (equals < 0) return;
    var key = line.slice(0, equals).trim();
    var value = line.slice(equals + 1).trim();
    if (key === 'token') token = value;
    if (key === 'expires') expires = value;
  });

  if (!token || !expires) {
    return false;
  }

  var expiresAt = new Date(expires);
  return !isNaN(expiresAt.getTime()) && expiresAt.getTime() > Date.now();
}

function isAfkFlagPath(value) {
  return normalizePath(value) === normalizePath(AFK_FLAG_PATH);
}

function normalizePath(value) {
  var raw = String(value || '').trim();
  if (/^~[\\/]\.claude(?:[\\/]|$)/i.test(raw)) {
    raw = CLAUDE_HOME + raw.slice(9);
  }
  return path.resolve(raw).replace(/[\\/]+/g, '\\').toLowerCase();
}

function isCriticalPath(value) {
  // Delegate to the shared predicate (also used by isSafeAfkBash's cp/mv/sed checks and by
  // backend-pretool-write.ps1's ported twin) so critical-path judgment has one source of truth
  // for the JS side. normalizePath first for tilde-expansion + absolute resolution.
  return isCriticalPathShared(normalizePath(value));
}

function allow() {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow'
    }
  };
}

function denyNeverList() {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: 'This command is on the AFK never-list.'
    }
  };
}

function askToArm() {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'ask',
      permissionDecisionReason: 'AFK arming requires explicit approval'
    }
  };
}
