#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HOOK = path.join(__dirname, 'context-cap-guard.js');
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'context-cap-guard-'));
let failures = 0;

function fixture(name, content) {
  const dir = fs.mkdtempSync(path.join(fixtureRoot, 'case-'));
  const file = path.join(dir, name);
  if (content !== undefined) fs.writeFileSync(file, content, 'utf8');
  return file;
}

function invoke(payload, raw = false) {
  const result = spawnSync(process.execPath, [HOOK], {
    input: raw ? payload : JSON.stringify(payload),
    encoding: 'utf8',
  });
  assert.strictEqual(result.status, 0, `hook exited ${result.status}: ${result.stderr}`);
  return result.stdout.trim();
}

function denyOutput(payload) {
  const stdout = invoke(payload);
  assert.notStrictEqual(stdout, '', 'expected deny JSON on stdout');
  const parsed = JSON.parse(stdout);
  assert.strictEqual(parsed?.hookSpecificOutput?.hookEventName, 'PreToolUse');
  assert.strictEqual(parsed?.hookSpecificOutput?.permissionDecision, 'deny');
  return parsed.hookSpecificOutput;
}

function assertAllowed(payload, raw = false) {
  assert.strictEqual(invoke(payload, raw), '', 'allowed operation must print nothing');
}

function writePayload(filePath, content) {
  return { tool_name: 'Write', tool_input: { file_path: filePath, content } };
}

function editPayload(filePath, oldString, newString, replaceAll = false) {
  return {
    tool_name: 'Edit',
    tool_input: {
      file_path: filePath,
      old_string: oldString,
      new_string: newString,
      replace_all: replaceAll,
    },
  };
}

function test(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}`);
    console.error(error.stack || error);
  }
}

try {
  test('Write growth on an already-over-cap file denies', () => {
    const file = fixture('status.md', 'x\n'.repeat(101));
    denyOutput(writePayload(file, 'x\n'.repeat(102)));
  });

  test('Edit growth into violation denies', () => {
    const file = fixture('status.md', 'x\n'.repeat(100));
    denyOutput(editPayload(file, 'x', 'x\n'));
  });

  test('shrinking Edit on an over-cap file allows', () => {
    const file = fixture('status.md', 'x\n'.repeat(101));
    assertAllowed(editPayload(file, 'x\n', 'x'));
  });

  test('equal-size Edit on an over-cap file allows', () => {
    const file = fixture('status.md', 'typo\n'.repeat(101));
    assertAllowed(editPayload(file, 'typo', 'type'));
  });

  test('under-cap Write allows', () => {
    const file = fixture('status.md');
    assertAllowed(writePayload(file, 'x\n'.repeat(99)));
  });

  test('brand-new over-cap Write denies', () => {
    const file = fixture('status.md');
    denyOutput(writePayload(file, 'x\n'.repeat(101)));
  });

  test('replace_all uses every occurrence in projection arithmetic', () => {
    const file = fixture('status.md', `${'z\n'.repeat(99)}mark mark`);
    const output = denyOutput(editPayload(file, 'mark', 'mark\n', true));
    assert.match(output.permissionDecisionReason, /projects to 101 lines/);
  });

  test('newline-terminated file at exact line cap allows equal-size Edit', () => {
    const file = fixture('status.md', 'x\n'.repeat(100));
    assertAllowed(editPayload(file, 'x', 'y'));
  });

  test('growth from exact line cap to cap plus one denies', () => {
    const file = fixture('status.md', 'x\n'.repeat(100));
    const output = denyOutput(editPayload(file, 'x', 'x\n'));
    assert.match(output.permissionDecisionReason, /projects to 101 lines/);
  });

  test('status.md line cap is inclusive for Write', () => {
    const file = fixture('status.md');
    assertAllowed(writePayload(file, 'x\n'.repeat(100)));
    denyOutput(writePayload(file, 'x\n'.repeat(101)));
  });

  test('CLAUDE.md line cap is inclusive for Write', () => {
    const file = fixture('CLAUDE.md');
    assertAllowed(writePayload(file, 'x\n'.repeat(200)));
    denyOutput(writePayload(file, 'x\n'.repeat(201)));
  });

  test('AGENTS.md Write at exactly 32768 bytes allows', () => {
    const file = fixture('AGENTS.md');
    assertAllowed(writePayload(file, 'a'.repeat(32768)));
  });

  test('AGENTS.md Write at 32769 bytes denies', () => {
    const file = fixture('AGENTS.md');
    const output = denyOutput(writePayload(file, 'a'.repeat(32769)));
    assert.match(output.permissionDecisionReason, /projects to 32769 bytes/);
  });

  test('non-cap file allows', () => {
    const file = fixture('notes.md');
    assertAllowed(writePayload(file, 'x\n'.repeat(1000)));
  });

  test('unparseable stdin allows', () => {
    assertAllowed('{not valid JSON', true);
  });
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

if (failures > 0) {
  console.error(`\n${failures} test(s) failed`);
  process.exitCode = 1;
} else {
  console.log('\nAll context-cap-guard tests passed');
}
