#!/usr/bin/env node
/**
 * context-cap-guard — PostToolUse (Write|Edit).  ADR-037.
 *
 * The three context files have hard caps. Prose rules did not hold them: status.md's own hygiene
 * rule said "current state only, no rolling session log" and it still reached 641 lines / 108 KB.
 * Anthropic's guidance is explicit — a rule that must hold with zero exceptions belongs in a hook,
 * because CLAUDE.md is advisory and hooks are deterministic.
 *
 * Caps and why they are what they are:
 *   status.md  <= 100 lines   — live state; past this it is a changelog, and an unbounded state
 *                               file degrades attention (worse than no state file at all).
 *   CLAUDE.md  <= 200 lines   — Anthropic: "Longer files consume more context and reduce
 *                               adherence." Bloat makes the model ignore the real instructions.
 *   AGENTS.md  <  32 KiB      — Codex's project_doc_max_bytes. Past it, content is SILENTLY
 *                               truncated with no warning (openai/codex#7138) — the file just
 *                               quietly stops being followed.
 *
 * Advisory, not blocking: it reports on the file that was just written, so the breach is caught at
 * the moment it is created rather than months later. Exit 0 always — never wedge a session.
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

function main() {
  let raw = '';
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch {
    process.exit(0);
  }

  let file;
  try {
    const ev = JSON.parse(raw);
    file = ev?.tool_input?.file_path;
  } catch {
    process.exit(0);
  }
  if (!file) process.exit(0);

  const base = path.basename(file);
  const cap = CAPS.find((c) => c.match.test(base));
  if (!cap) process.exit(0);

  let stat;
  try {
    stat = fs.readFileSync(file, 'utf8');
  } catch {
    process.exit(0);
  }

  const size = cap.unit === 'lines'
    ? stat.split('\n').length
    : Buffer.byteLength(stat, 'utf8');

  if (size <= cap.limit) process.exit(0);

  const over = size - cap.limit;
  const label = cap.unit === 'bytes'
    ? `${size} bytes (cap ${cap.limit}, over by ${over})`
    : `${size} lines (cap ${cap.limit}, over by ${over})`;

  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext:
        `⚠️  CONTEXT CAP BREACHED — ${base} is ${label}.\n\n${cap.fix}\n\n` +
        `Fix it now, in this turn, before moving on. The cap is not a style preference: ` +
        `past it the file measurably stops working — the model ignores it, or (AGENTS.md) never ` +
        `sees the overflow at all.`,
    },
  }));
  process.exit(0);
}

main();
