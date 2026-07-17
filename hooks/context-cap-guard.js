#!/usr/bin/env node
/**
 * context-cap-guard - blocking PreToolUse gate for Write|Edit|MultiEdit. ADR-037, refined by ADR-041.
 *
 * Deterministically projects the size of a capped context file before the tool runs and denies
 * growth past its inclusive cap. An edit whose projected size does not exceed the on-disk size is
 * always allowed, even when the file is already over cap, so cleanup fixes cannot be blocked.
 *
 * Line caps use wc -l semantics: size is the number of newline (\n) characters, not the number of
 * strings produced by splitting on a newline.
 *
 * Caps and why they are what they are:
 *   status.md  <= 100 lines   - live state; past this it is a changelog, and an unbounded state
 *                               file degrades attention (worse than no state file at all).
 *   CLAUDE.md  <= 200 lines   - longer files consume more context and reduce adherence; bloat
 *                               makes the model ignore the real instructions.
 *   AGENTS.md  <= 32768 bytes - Codex's project_doc_max_bytes (32768 allowed; 32769+ denied).
 *                               Past it, content is silently truncated without warning.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_STDIN_TIMEOUT_MS = 3000;

const CAPS = [
  { match: /(^|[\\/])status\.md$/i, unit: 'lines', limit: 100,
    fix: 'status.md is LIVE STATE. Rewrite it, do not append. Delete finished In-Flight rows (git has them) and resolved Open Questions. Session narrative belongs in docs/handoff/, decisions in an ADR.' },
  { match: /(^|[\\/])CLAUDE\.md$/i, unit: 'lines', limit: 200,
    fix: 'Anthropic caps CLAUDE.md at ~200 lines — past it, adherence drops and rules get ignored. Move workflow detail to a skill (loaded on demand) and repo detail to AGENTS.md. Note @imports are EAGER: splitting into imports does NOT reduce context.' },
  { match: /(^|[\\/])AGENTS\.md$/i, unit: 'bytes', limit: 32768,
    fix: 'Codex silently truncates past 32 KiB — the overflow is not read and you get no warning. Cut to the commands and gotchas the model cannot derive; move the rest to nested per-directory AGENTS.md files.' },
];

function newlineCount(content) {
  let count = 0;
  for (let i = 0; i < content.length; i += 1) {
    if (content.charCodeAt(i) === 10) count += 1;
  }
  return count;
}

function countOccurrences(content, needle) {
  if (needle.length === 0) return 0;

  let count = 0;
  let start = 0;
  while (true) {
    const index = content.indexOf(needle, start);
    if (index === -1) return count;
    count += 1;
    start = index + needle.length;
  }
}

function isNonArrayObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function deny(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  };
}

function exitDenied(reason) {
  process.stdout.write(JSON.stringify(deny(reason)), () => process.exit(0));
}

function configuredStdinTimeout() {
  const raw = String(process.env.APEX_GUARD_STDIN_TIMEOUT_MS || '').trim();
  if (!/^[1-9]\d*$/.test(raw)) return DEFAULT_STDIN_TIMEOUT_MS;

  const milliseconds = Number(raw);
  return Number.isSafeInteger(milliseconds) && milliseconds <= 2147483647
    ? milliseconds
    : DEFAULT_STDIN_TIMEOUT_MS;
}

function projectMultiEdit(currentContent, edits, sizeOf) {
  let running = currentContent;

  for (const edit of edits) {
    if (!isNonArrayObject(edit) || typeof edit.old_string !== 'string' ||
        typeof edit.new_string !== 'string') {
      return null;
    }

    const occurrences = edit.replace_all
      ? countOccurrences(running, edit.old_string)
      : 1;

    // Claude Code treats an empty old_string as one insertion, even though there are no
    // non-overlapping occurrences to count.
    if (edit.old_string.length === 0) {
      running = edit.new_string + running;
    } else if (occurrences > 0) {
      running = edit.replace_all
        ? running.split(edit.old_string).join(edit.new_string)
        : running.replace(edit.old_string, edit.new_string);
    }
  }

  return sizeOf(running);
}

function main(raw) {
  let ev;
  try {
    ev = JSON.parse(raw);
  } catch {
    exitDenied('Context cap guard blocked the tool call because its input was not validated.');
    return;
  }

  if (!isNonArrayObject(ev)) {
    exitDenied('Context cap guard blocked the tool call because its input was not validated.');
    return;
  }

  if (!Object.prototype.hasOwnProperty.call(ev, 'tool_input')) process.exit(0);
  if (!isNonArrayObject(ev.tool_input)) {
    exitDenied('Context cap guard blocked the tool call because its input was not validated.');
    return;
  }

  const input = ev.tool_input;
  const file = input.file_path;
  if (file === undefined || file === null || file === '') process.exit(0);
  if (typeof file !== 'string') {
    exitDenied('Context cap guard blocked the tool call because its input was not validated.');
    return;
  }

  const base = path.basename(file);
  const cap = CAPS.find((candidate) => candidate.match.test(base));
  if (!cap) process.exit(0);

  let currentContent = '';
  try {
    currentContent = fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      exitDenied(
        `Context cap guard blocked the tool call because ${base} could not be read and validated.`
      );
      return;
    }
  }

  const sizeOf = (content) => cap.unit === 'lines'
    ? newlineCount(content)
    : Buffer.byteLength(content, 'utf8');
  const current = sizeOf(currentContent);

  let projected;
  const hasContent = Object.prototype.hasOwnProperty.call(input, 'content');
  const hasOldString = Object.prototype.hasOwnProperty.call(input, 'old_string');
  const hasNewString = Object.prototype.hasOwnProperty.call(input, 'new_string');
  const hasEdits = Object.prototype.hasOwnProperty.call(input, 'edits');

  if ((hasContent && typeof input.content !== 'string') ||
      ((hasOldString || hasNewString) &&
       (typeof input.old_string !== 'string' || typeof input.new_string !== 'string')) ||
      (hasEdits && !Array.isArray(input.edits))) {
    exitDenied('Context cap guard blocked the tool call because its input was not validated.');
    return;
  }

  if (hasContent) {
    projected = sizeOf(input.content);
  } else if (hasOldString || hasNewString) {
    const occurrences = input.replace_all
      ? countOccurrences(currentContent, input.old_string)
      : 1;
    projected = current + occurrences * (sizeOf(input.new_string) - sizeOf(input.old_string));
  } else if (hasEdits) {
    projected = projectMultiEdit(currentContent, input.edits, sizeOf);
    if (projected === null) {
      exitDenied('Context cap guard blocked the tool call because its input was not validated.');
      return;
    }
  } else {
    process.exit(0);
  }

  if (projected <= cap.limit || projected <= current) process.exit(0);

  const over = projected - cap.limit;
  const label = cap.unit === 'bytes'
    ? `${projected} bytes (cap ${cap.limit}, over by ${over})`
    : `${projected} lines (cap ${cap.limit}, over by ${over})`;

  exitDenied(`CONTEXT CAP BLOCKED - ${base} projects to ${label}.\n\n${cap.fix}`);
}

let rawInput = '';
let stdinSettled = false;
const stdinTimeout = setTimeout(() => {
  stdinSettled = true;
  exitDenied(
    'Context cap guard blocked the tool call because input was not received or validated before the stdin timeout.'
  );
}, configuredStdinTimeout());

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { rawInput += chunk; });
process.stdin.on('error', () => {
  if (stdinSettled) return;
  stdinSettled = true;
  clearTimeout(stdinTimeout);
  exitDenied('Context cap guard blocked the tool call because its input was not validated.');
});
process.stdin.on('end', () => {
  if (stdinSettled) return;
  stdinSettled = true;
  clearTimeout(stdinTimeout);
  main(rawInput);
});
