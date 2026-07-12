#!/usr/bin/env node
/**
 * PreToolUse Hook: Destructive-Command Hard-Block
 *
 * Hard-blocks never-list destructive commands when running in coding mode.
 * Contract: reads PreToolUse JSON from stdin; writes deny decision JSON
 * to stdout on match; exits 0 either way.
 */

'use strict';

var detection = require('./lib/destructive-detect');
var isDestructiveBash = detection.isDestructiveBash;
var isReadOnlyGitIntrospection = detection.isReadOnlyGitIntrospection;

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
    // Parse error or unexpected input — allow the tool call
  }

  process.exit(0);
});

function handlePreToolUse(data) {
  var disableVal = String(process.env.APEX_DESTRUCT_GUARD || '').trim().toLowerCase();
  if (disableVal === '0' || disableVal === 'false' || disableVal === 'off' || disableVal === 'disabled') {
    return null;
  }

  var baseUrl = String(process.env.ANTHROPIC_BASE_URL || '');
  var codingMode = baseUrl.indexOf('deepseek') >= 0 ||
    String(process.env.APEX_MODE || '').toLowerCase() === 'coding';
  if (!codingMode) {
    return null;
  }

  if (data.tool_name !== 'Bash') {
    return null;
  }

  var command = (data.tool_input && data.tool_input.command) || '';
  if (!command) {
    return null;
  }

  if (isReadOnlyGitIntrospection(command)) {
    return null;
  }

  if (isDestructiveBash(command)) {
    return {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: 'This command is on the APEX destructive-command never-list and is blocked in coding mode. If you need to run it deliberately, restart with APEX_DESTRUCT_GUARD=off set in the environment.'
      }
    };
  }

  return null;
}
