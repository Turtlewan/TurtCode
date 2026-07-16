#!/usr/bin/env node
/**
 * context-cap-guard - blocking PreToolUse gate for Write|Edit. ADR-037, refined by ADR-041.
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

function main() {
  let raw = '';
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch {
    process.exit(0);
  }

  let ev;
  try {
    ev = JSON.parse(raw);
  } catch {
    process.exit(0);
  }

  const input = ev?.tool_input;
  const file = input?.file_path;
  if (!file) process.exit(0);

  const base = path.basename(file);
  const cap = CAPS.find((candidate) => candidate.match.test(base));
  if (!cap) process.exit(0);

  let currentContent = '';
  try {
    currentContent = fs.readFileSync(file, 'utf8');
  } catch {}

  const sizeOf = (content) => cap.unit === 'lines'
    ? newlineCount(content)
    : Buffer.byteLength(content, 'utf8');
  const current = sizeOf(currentContent);

  let projected;
  if (Object.prototype.hasOwnProperty.call(input, 'content') &&
      typeof input.content === 'string') {
    projected = sizeOf(input.content);
  } else if (typeof input.old_string === 'string' &&
             typeof input.new_string === 'string') {
    const occurrences = input.replace_all
      ? countOccurrences(currentContent, input.old_string)
      : 1;
    projected = current + occurrences * (sizeOf(input.new_string) - sizeOf(input.old_string));
  } else {
    process.exit(0);
  }

  if (projected <= cap.limit || projected <= current) process.exit(0);

  const over = projected - cap.limit;
  const label = cap.unit === 'bytes'
    ? `${projected} bytes (cap ${cap.limit}, over by ${over})`
    : `${projected} lines (cap ${cap.limit}, over by ${over})`;

  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `CONTEXT CAP BLOCKED - ${base} projects to ${label}.\n\n${cap.fix}`,
    },
  }));
  process.exit(0);
}

main();
