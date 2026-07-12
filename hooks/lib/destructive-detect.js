'use strict';

const DESTRUCTIVE_SQL_DD = /\b(drop\s+table|delete\s+from|truncate|dd\s+if=)\b/i;

function stripQuotedStrings(input) {
  return input
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

function explodeSubshells(input) {
  let out = input;
  for (let i = 0; i < 4; i += 1) {
    const before = out;
    out = out.replace(/\$\(([^()`]*)\)/g, ';$1;');
    out = out.replace(/`([^`]*)`/g, ';$1;');
    if (out === before) break;
  }
  return out;
}

function splitCommandSegments(input) {
  const stripped = explodeSubshells(stripQuotedStrings(input));
  return stripped
    .split(/[;|&]+/)
    .map(function(segment) { return segment.replace(/(^|\s)#.*/, '$1').trim(); })
    .filter(Boolean);
}

function tokenize(segment) {
  return segment.split(/\s+/).filter(Boolean);
}

function tokenizeAllowlistedShellWords(input) {
  var tokens = [];
  var current = '';
  var quote = null;
  var escaped = false;

  for (var ci = 0; ci < String(input || '').length; ci++) {
    var char = String(input || '')[ci];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === '\\') {
      escaped = true;
      continue;
    }

    if (quote) {
      if (char === quote) {
        quote = null;
      } else {
        current += char;
      }
      continue;
    }

    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }

    if (/\s/.test(char)) {
      if (current) {
        tokens.push(current);
        current = '';
      }
      continue;
    }

    current += char;
  }

  if (escaped) current += '\\';
  if (quote) return null;
  if (current) tokens.push(current);
  return tokens;
}

function commandBasename(token) {
  if (!token) return '';
  return token.replace(/^.*[\\/]/, '').replace(/\.exe$/i, '').toLowerCase();
}

function isDestructiveRm(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'rm') return false;
  var hasR = false;
  var hasF = false;
  for (var ti = 1; ti < tokens.length; ti++) {
    var t = tokens[ti];
    if (t === '--recursive') { hasR = true; continue; }
    if (t === '--force') { hasF = true; continue; }
    if (!t.startsWith('-') || t.startsWith('--')) continue;
    var body = t.slice(1);
    if (/[rR]/.test(body)) hasR = true;
    if (/f/.test(body)) hasF = true;
  }
  return hasR && hasF;
}

function findGitSubcommand(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'git') return null;
  var valueConsumingShort = new Set(['-c', '-C']);
  var valueConsumingLong = new Set(['--git-dir', '--work-tree', '--namespace', '--super-prefix']);
  var i = 1;
  while (i < tokens.length) {
    var t = tokens[i];
    if (valueConsumingShort.has(t) || valueConsumingLong.has(t)) {
      i += 2;
      continue;
    }
    if (t.startsWith('--git-dir=') || t.startsWith('--work-tree=') || t.startsWith('--namespace=') || t.startsWith('--super-prefix=')) {
      i += 1;
      continue;
    }
    if (t.startsWith('-')) {
      i += 1;
      continue;
    }
    return { command: t.toLowerCase(), rest: tokens.slice(i + 1) };
  }
  return null;
}

function isDestructiveGit(tokens) {
  var sub = findGitSubcommand(tokens);
  if (!sub) return false;
  var command = sub.command;
  var rest = sub.rest;

  if (command === 'reset') {
    return rest.indexOf('--hard') >= 0;
  }

  if (command === 'checkout') {
    return rest.indexOf('--') >= 0;
  }

  if (command === 'clean') {
    return rest.some(function(t) {
      if (t === '--force') return true;
      if (!t.startsWith('-') || t.startsWith('--')) return false;
      return t.slice(1).indexOf('f') >= 0;
    });
  }

  if (command === 'push') {
    var withLease = false;
    var bareForce = false;
    var plusRefspecForce = false;
    var mainOrMaster = false;

    for (var ri = 0; ri < rest.length; ri++) {
      var t = rest[ri];
      if (t === '--force-with-lease' || t.startsWith('--force-with-lease=')) {
        withLease = true;
      } else if (t === '--force' || t.startsWith('--force=')) {
        bareForce = true;
      } else if (t.startsWith('-') && !t.startsWith('--') && t.slice(1).indexOf('f') >= 0) {
        bareForce = true;
      } else if (t.startsWith('+') && t.length > 1 && /^\+(?:[a-zA-Z_/.:]|HEAD)/.test(t)) {
        var refNoPlus = t.slice(1);
        var ci = refNoPlus.indexOf(':');
        var dst = ci >= 0 ? refNoPlus.slice(ci + 1) : refNoPlus;
        if (dst === 'main' || dst === 'master') mainOrMaster = true;
      } else if (!t.startsWith('-')) {
        var colonIdx = t.indexOf(':');
        var target = colonIdx >= 0 ? t.slice(colonIdx + 1) : t;
        if (target === 'main' || target === 'master') {
          mainOrMaster = true;
        }
      }
    }

    var isForcePush = bareForce || (plusRefspecForce && !withLease);
    return isForcePush || mainOrMaster;
  }

  if (command === 'commit') {
    return rest.indexOf('--amend') >= 0 || rest.indexOf('--no-verify') >= 0;
  }

  if (command === 'rm') {
    var hasR = false;
    for (var rmi = 0; rmi < rest.length; rmi++) {
      var rmt = rest[rmi];
      if (!rmt.startsWith('-') || rmt.startsWith('--')) continue;
      if (/[rR]/.test(rmt.slice(1))) hasR = true;
    }
    return hasR;
  }

  if (command === 'switch') {
    return rest.some(function(t) {
      if (t === '--discard-changes' || t === '--force') return true;
      if (!t.startsWith('-') || t.startsWith('--')) return false;
      var body = t.slice(1);
      return /[fC]/.test(body);
    });
  }

  return false;
}

function isDestructiveBash(command) {
  var raw = String(command || '');
  var flattened = explodeSubshells(stripQuotedStrings(raw));
  if (DESTRUCTIVE_SQL_DD.test(flattened)) return true;

  var segments = splitCommandSegments(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    if (DESTRUCTIVE_SQL_DD.test(stripQuotedStrings(segment))) return true;
    var tokens = tokenize(segment);
    if (isDestructiveRm(tokens)) return true;
    if (isDestructiveGit(tokens)) return true;
  }
  return false;
}

function isReadOnlyGitIntrospection(command) {
  var trimmed = String(command || '').trim();
  if (!trimmed || /[\r\n;&|><`$()]/.test(trimmed)) {
    return false;
  }

  var segments = splitCommandSegments(trimmed);
  if (segments.length !== 1) {
    return false;
  }

  var tokens = tokenizeAllowlistedShellWords(trimmed);
  if (!tokens) {
    return false;
  }
  if (commandBasename(tokens[0]) !== 'git' || tokens.length < 2) {
    return false;
  }

  var subcommand = tokens[1].toLowerCase();
  var args = tokens.slice(2);

  if (subcommand === 'status') {
    return args.every(function(arg) { return ['--porcelain', '--short', '--branch'].indexOf(arg) >= 0; });
  }

  if (subcommand === 'diff') {
    return args.length <= 1 && args.every(function(arg) { return ['--name-only', '--name-status'].indexOf(arg) >= 0; });
  }

  if (subcommand === 'log') {
    return args.every(function(arg) { return arg === '--oneline' || /^--max-count=\d+$/.test(arg); });
  }

  if (subcommand === 'show') {
    return args.length === 1 && !args[0].startsWith('--') && /^[a-zA-Z0-9._:\/ -]+$/.test(args[0]);
  }

  if (subcommand === 'branch') {
    return args.length === 1 && args[0] === '--show-current';
  }

  if (subcommand === 'rev-parse') {
    return args.length === 2 && args[0] === '--abbrev-ref' && /^head$/i.test(args[1]);
  }

  return false;
}

function isNetworkCommand(tokens) {
  var head = commandBasename(tokens[0]);
  return head === 'curl' || head === 'wget' || head === 'iwr' || head === 'irm' ||
    head === 'invoke-webrequest' || head === 'invoke-restmethod';
}

function hasUploadOrBodyFlag(tokens) {
  for (var ti = 1; ti < tokens.length; ti++) {
    var token = String(tokens[ti] || '').toLowerCase();
    var next = String(tokens[ti + 1] || '').toLowerCase();

    if (token === '-t' || token === '-f' || token === '-d' ||
        token.indexOf('-t') === 0 || token.indexOf('-f') === 0 || token.indexOf('-d') === 0 ||
        token === '--upload-file' || token.indexOf('--upload-file=') === 0 ||
        token === '--data' || token.indexOf('--data') === 0 ||
        token === '-body' || token.indexOf('-body:') === 0 ||
        token === '-infile' || token.indexOf('-infile:') === 0) {
      return true;
    }

    if (token === '-x' && (next === 'post' || next === 'put')) return true;
    if (/^-x(?:post|put)$/.test(token)) return true;
    if (token === '-method' && (next === 'post' || next === 'put')) return true;
    if (/^-method:(?:post|put)$/.test(token)) return true;
  }
  return false;
}

function isSecretRead(substitution) {
  return /\b(?:cat|type|get-content)\b[^\r\n;|&]*(?:\.env\b|(?:secret|credential)[^\s;|&]*)/i.test(substitution);
}

function hasSecretCommandSubstitution(command) {
  var raw = String(command || '');
  var substitution = /\$\(([^)]*)\)|\x60([^\x60]*)\x60/g;
  var match;
  while ((match = substitution.exec(raw))) {
    if (isSecretRead(match[1] || match[2] || '')) return true;
  }
  return false;
}

function isExfiltrationBash(command) {
  var raw = String(command || '');
  var segments = splitCommandSegments(raw);
  var hasSecretSubstitution = hasSecretCommandSubstitution(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    var tokens = tokenize(segment);
    if (!isNetworkCommand(tokens)) continue;
    if (hasUploadOrBodyFlag(tokens) || hasSecretSubstitution) {
      return true;
    }
  }
  return false;
}

function isRemoteCodeExec(command) {
  var flattened = explodeSubshells(stripQuotedStrings(String(command || '')));
  return /(?:^|[;|&\s])(?:[^\s;|&]*[\\/])?(?:curl|wget|iwr|irm|invoke-[a-z0-9-]+)(?:\.exe)?\b[^;|&]*\|\s*(?:[^\s;|&]*[\\/])?(?:bash|sh|zsh|pwsh|powershell|iex|invoke-expression|node|python)(?:\.exe)?\b/i.test(flattened);
}

function isAfkTarget(value) {
  return /(?:~|\$home)[\\/]\.claude[\\/]afk\.on\b/i.test(value) ||
    /c:[\\/]+users[\\/]+user[\\/]+\.claude[\\/]+afk\.on\b/i.test(value);
}

function isCriticalPath(value) {
  var raw = String(value || '');
  var normalized = raw.replace(/\//g, '\\').toLowerCase();
  var basename = normalized.split('\\').pop();

  if (/\.env(?:\..*)?$/.test(basename)) return true;
  if (/(^|\\)migrations(\\|$)/.test(normalized)) return true;
  if (/(^|\\)alembic\\versions(\\|$)/.test(normalized)) return true;
  if (normalized.indexOf('auth') >= 0 || normalized.indexOf('guard') >= 0) return true;
  if (/(^|\\)\.github\\workflows(\\|$)/.test(normalized)) return true;
  if (basename === '.gitlab-ci.yml') return true;
  if (/(^|\\)\.circleci(\\|$)/.test(normalized)) return true;
  if (/^azure-pipelines/.test(basename)) return true;
  var manifests = ['package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock',
    'pyproject.toml', 'poetry.lock', 'cargo.toml', 'cargo.lock', 'go.mod', 'go.sum'];
  if (manifests.indexOf(basename) >= 0 || /^requirements.*\.txt$/.test(basename)) return true;
  if (basename === '.npmrc' || basename === '.netrc') return true;
  if (/(^|\\)\.ssh(\\|$)/.test(normalized)) return true;
  if (/^id_rsa/.test(basename) || /\.(pem|key)$/.test(basename)) return true;
  if (normalized.indexOf('secret') >= 0 || normalized.indexOf('credential') >= 0) return true;
  // Self-config: the guard's own live hooks/settings must never be a "safe" bypass target,
  // whether reached via Write/Edit or via a Bash copy/move (BLOCK 3, cross-model review).
  if (/(^|\\)\.claude\\hooks(\\|$)/.test(normalized)) return true;
  if (basename === 'settings.json' && normalized.indexOf('\\.claude\\') >= 0) return true;

  return false;
}

function isAfkFlagWrite(command) {
  var raw = String(command || '');
  if (!isAfkTarget(raw)) return false;
  // Any shell redirect at all, combined with the target-path check above (tilde OR the real
  // absolute path — BLOCK 2, cross-model review), means this command writes the flag.
  if (/(?:^|[^<])>{1,2}/.test(raw)) {
    return true;
  }

  var segments = splitCommandSegments(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    var tokens = tokenize(segment);
    var head = commandBasename(tokens[0]);
    if (['tee', 'set-content', 'add-content', 'out-file', 'new-item', 'cp',
      'copy-item', 'move-item', 'mv', 'touch', 'install', 'dd', 'truncate',
      'clear-content', 'remove-item', 'rm', 'del', 'erase'].indexOf(head) >= 0 &&
        isAfkTarget(raw)) {
      return true;
    }
  }
  return false;
}

// Deliberately EXCLUDES general-purpose interpreters / package managers / AI CLIs (node, python,
// py, npx, npm, pnpm, yarn, uv, uvx, pip, pytest, tsc, eslint, ruff, mypy, cargo, go, codex,
// claude) — each executes arbitrary code from its own arguments/lockfile-scripts in a way no
// destructive/exfil/RCE detector can safely allowlist by command head alone (cross-model review
// BLOCK 1). Unattended builds needing them fall through to the normal dontAsk gate instead of
// auto-allow — a real usability cost, but the only way this stays a true fail-closed allowlist.
var SAFE_AFK_COMMANDS = new Set([
  'taskkill', 'stop-process', 'start-job', 'get-process', 'wait-job', 'kill', 'ls', 'dir',
  'get-childitem', 'cat', 'get-content', 'type', 'echo', 'printf', 'grep',
  'rg', 'find', 'wc', 'sed', 'head', 'tail', 'mkdir', 'new-item', 'cp',
  'copy-item', 'move-item', 'mv', 'git'
]);

// Heads whose destination/target argument must be checked against isCriticalPath even though
// the command itself is on the safe list -- these can overwrite an arbitrary file, including the
// guard's own hooks/settings (BLOCK 3).
var FILE_WRITE_HEADS = new Set(['cp', 'copy-item', 'move-item', 'mv', 'new-item']);

function hasCriticalWriteTarget(tokens) {
  for (var ti = 1; ti < tokens.length; ti++) {
    if (isCriticalPath(tokens[ti])) return true;
  }
  return false;
}

function isFindUnsafe(tokens) {
  var unsafeFlags = ['-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprintf'];
  for (var ti = 1; ti < tokens.length; ti++) {
    if (unsafeFlags.indexOf(tokens[ti].toLowerCase()) >= 0) return true;
  }
  return false;
}

function isSedUnsafe(tokens) {
  var inPlace = false;
  for (var ti = 1; ti < tokens.length; ti++) {
    var t = tokens[ti];
    if (t === '-i' || t.indexOf('-i') === 0 || t === '--in-place' || t.indexOf('--in-place=') === 0) {
      inPlace = true;
    }
  }
  return inPlace && hasCriticalWriteTarget(tokens);
}

function isGitConfigInjection(tokens) {
  for (var ti = 1; ti < tokens.length; ti++) {
    var t = tokens[ti];
    if (t === '-c' || t === '--config-env' || t.indexOf('--config-env=') === 0) return true;
  }
  return false;
}

function isSafeAfkBash(command) {
  var raw = String(command || '');
  if (!raw.trim() || isDestructiveBash(raw) || isExfiltrationBash(raw) ||
      isRemoteCodeExec(raw) || isAfkFlagWrite(raw)) {
    return false;
  }

  var segments = splitCommandSegments(raw);
  if (segments.length === 0) return false;
  for (var si = 0; si < segments.length; si++) {
    var tokens = tokenize(segments[si]);
    var head = commandBasename(tokens[0]);
    if (tokens.length === 0 || !SAFE_AFK_COMMANDS.has(head)) {
      return false;
    }
    if (head === 'git' && (isDestructiveGit(tokens) || isGitConfigInjection(tokens))) {
      return false;
    }
    if (head === 'find' && isFindUnsafe(tokens)) {
      return false;
    }
    if (head === 'sed' && isSedUnsafe(tokens)) {
      return false;
    }
    if (FILE_WRITE_HEADS.has(head) && hasCriticalWriteTarget(tokens)) {
      return false;
    }
  }
  return true;
}

module.exports = {
  isDestructiveBash: isDestructiveBash,
  isReadOnlyGitIntrospection: isReadOnlyGitIntrospection,
  isExfiltrationBash: isExfiltrationBash,
  isRemoteCodeExec: isRemoteCodeExec,
  isAfkFlagWrite: isAfkFlagWrite,
  isSafeAfkBash: isSafeAfkBash,
  isCriticalPath: isCriticalPath
};
