'use strict';

const DESTRUCTIVE_SQL_DD = /\b(drop\s+(table|schema|database)|delete\s+from|truncate)\b/i;

// Keep this vocabulary aligned with codex-dispatch-guard.js's TRANSPARENT_RUNNERS. `nice` is
// included because it is also a transparent command prefix for destructive-command detection.
const TRANSPARENT_RUNNERS = new Set([
  'npx', 'bunx', 'env', 'xargs', 'nohup', 'time', 'command', 'sudo', 'doas', 'start', 'winpty',
  'nice'
]);

// Heads that only READ. A destructive-looking string in their arguments is data, not an action --
// `grep "<sql>" migrations/` must not be blocked. Anything NOT on this list gets its RAW
// (quotes-intact) command tested against DESTRUCTIVE_SQL_DD. See isDestructiveBash.
const READONLY_HEADS = new Set([
  'grep', 'rg', 'ag', 'cat', 'bat', 'less', 'more', 'head', 'tail', 'echo', 'printf',
  'find', 'ls', 'dir', 'wc', 'diff', 'awk', 'jq', 'git', 'type', 'get-content', 'select-string'
]);

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

function unwrapTransparentRunners(tokens) {
  var i = 0;

  while (i < tokens.length) {
    var runner = commandBasename(tokens[i]);
    if (!TRANSPARENT_RUNNERS.has(runner)) break;
    i += 1;

    if (runner === 'env') {
      while (i < tokens.length) {
        var envToken = tokens[i];
        if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(envToken)) {
          i += 1;
        } else if (envToken === '-i' || envToken === '--ignore-environment') {
          i += 1;
        } else if (envToken === '-u' || envToken === '--unset') {
          i += 2;
        } else if (/^(?:-u[^-].*|--unset=.+)$/.test(envToken)) {
          i += 1;
        } else if (envToken === '--') {
          i += 1;
          break;
        } else {
          break;
        }
      }
      continue;
    }

    if (runner === 'nice') {
      if (i < tokens.length && (tokens[i] === '-n' || tokens[i] === '--adjustment')) {
        i += 2;
      } else if (i < tokens.length && /^(?:-n.+|--adjustment=.+)$/.test(tokens[i])) {
        i += 1;
      }
      continue;
    }

    // Match the dispatch guard's treatment of runner-owned switches. Operand-taking runner
    // options beyond env/nice are outside this careless-operator threat model.
    while (i < tokens.length && /^(?:-{1,2}[A-Za-z0-9][^\s]*|\/[A-Za-z])$/.test(tokens[i])) {
      i += 1;
    }
  }

  return tokens.slice(i);
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

function isPowerShellSwitch(token, fullName, minimumPrefixLength) {
  var value = String(token || '').toLowerCase();
  if (value[0] !== '-') return false;
  var name = value.slice(1);
  return name.length >= minimumPrefixLength && fullName.indexOf(name) === 0;
}

function isDestructivePowerShellRemove(tokens) {
  if (tokens.length === 0) return false;
  var head = commandBasename(tokens[0]);
  if (['remove-item', 'ri', 'rm', 'rmdir', 'rd', 'del', 'erase'].indexOf(head) < 0) {
    return false;
  }

  var hasRecurse = tokens.some(function(token) {
    return isPowerShellSwitch(token, 'recurse', 1);
  });
  var hasForce = tokens.some(function(token) {
    return isPowerShellSwitch(token, 'force', 2);
  });
  return hasRecurse && hasForce;
}

function isDestructiveCmdDelete(tokens) {
  if (tokens.length === 0) return false;
  var head = commandBasename(tokens[0]);
  if (['rmdir', 'rd', 'del', 'erase'].indexOf(head) < 0) return false;

  var options = tokens.slice(1).map(function(token) { return String(token).toLowerCase(); });
  return options.indexOf('/s') >= 0 && options.indexOf('/q') >= 0;
}

function isClearContent(tokens) {
  return tokens.length > 1 && commandBasename(tokens[0]) === 'clear-content';
}

function isDestructiveDd(tokens) {
  return tokens.length > 1 && commandBasename(tokens[0]) === 'dd' &&
    tokens.slice(1).some(function(token) { return token.startsWith('if='); });
}

function unwrapOuterQuotes(input) {
  var value = String(input || '').trim();
  if (value.length >= 2) {
    var first = value[0];
    var last = value[value.length - 1];
    if ((first === "'" && last === "'") || (first === '"' && last === '"')) {
      return value.slice(1, -1).trim();
    }
  }
  return value;
}

function extractQuotedStrings(input) {
  var strings = [];
  var quote = null;
  var current = '';
  var escaped = false;
  var raw = String(input || '');

  for (var ci = 0; ci < raw.length; ci++) {
    var char = raw[ci];
    if (!quote) {
      if (char === "'" || char === '"') {
        quote = char;
        current = '';
      }
      continue;
    }

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === '`' || (char === '\\' && quote === '"')) {
      escaped = true;
      continue;
    }
    if (char === quote) {
      strings.push(current);
      quote = null;
      current = '';
      continue;
    }
    current += char;
  }

  return strings;
}

function extractBraceBlocks(input) {
  var blocks = [];
  var raw = String(input || '');
  var depth = 0;
  var start = -1;
  var quote = null;
  var escaped = false;

  for (var ci = 0; ci < raw.length; ci++) {
    var char = raw[ci];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote) {
      if (char === '`' || (char === '\\' && quote === '"')) {
        escaped = true;
      } else if (char === quote) {
        quote = null;
      }
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === '{') {
      if (depth === 0) start = ci + 1;
      depth += 1;
    } else if (char === '}' && depth > 0) {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        blocks.push(raw.slice(start, ci));
        start = -1;
      }
    }
  }
  return blocks;
}

function retestCarrierPayload(payload, depth) {
  var inner = unwrapOuterQuotes(payload);
  inner = inner.replace(/^\s*(?:-c(?:ommand)?|\/c)\s+/i, '');
  inner = unwrapOuterQuotes(inner);
  return inner.length > 0 && isDestructiveBash(inner, depth + 1);
}

function isDestructiveCarrier(command, segments, depth) {
  if (depth >= 6) return false;
  var raw = String(command || '');
  var carrierHeads = new Set([
    'invoke-expression', 'iex', 'invoke-command', 'start-process', 'start-job',
    'powershell', 'pwsh', 'cmd'
  ]);
  var hasCarrier = false;

  for (var si = 0; si < segments.length; si++) {
    var tokens = unwrapTransparentRunners(tokenize(segments[si]));
    if (tokens.length === 0) continue;
    var head = commandBasename(tokens[0]);
    if (!carrierHeads.has(head)) continue;
    hasCarrier = true;

    if (head === 'cmd') {
      var cmdIndex = tokens.findIndex(function(token) { return /^\/c$/i.test(token); });
      if (cmdIndex >= 0 && retestCarrierPayload(tokens.slice(cmdIndex + 1).join(' '), depth)) {
        return true;
      }
      continue;
    }

    if (head === 'powershell' || head === 'pwsh') {
      var commandIndex = tokens.findIndex(function(token) { return /^-c(?:ommand)?$/i.test(token); });
      if (commandIndex >= 0 && retestCarrierPayload(tokens.slice(commandIndex + 1).join(' '), depth)) {
        return true;
      }
      continue;
    }

    if (tokens.length > 1 && retestCarrierPayload(tokens.slice(1).join(' '), depth)) {
      return true;
    }
  }

  if (hasCarrier) {
    var quoted = extractQuotedStrings(raw);
    for (var qi = 0; qi < quoted.length; qi++) {
      if (retestCarrierPayload(quoted[qi], depth)) return true;
    }
  }

  var hasScriptBlockCarrier = /(?:^|[;\r\n])\s*(?:&|\.)\s*\{/m.test(raw) ||
    /\b(?:invoke-command|start-job)\b[^{}]*\{/i.test(raw);
  if (hasScriptBlockCarrier) {
    var blocks = extractBraceBlocks(raw);
    for (var bi = 0; bi < blocks.length; bi++) {
      if (retestCarrierPayload(blocks[bi], depth)) return true;
    }
  }

  return false;
}

function findGitSubcommand(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'git') return null;
  var valueConsumingShort = new Set(['-c', '-C']);
  var valueConsumingLong = new Set(['--git-dir', '--work-tree', '--namespace', '--super-prefix']);
  var i = 1;
  while (i < tokens.length) {
    var t = tokens[i];
    var value = null;
    if (valueConsumingShort.has(t) || valueConsumingLong.has(t)) {
      i += 1;
      value = tokens[i] || '';
    } else if (/^(?:-c|-C|--git-dir|--work-tree|--namespace|--super-prefix)=/.test(t)) {
      value = t.slice(t.indexOf('=') + 1);
    }
    if (value !== null) {
      // Whitespace tokenization can split a quoted global-option value across words.
      var quoteIndex = value.search(/['"]/);
      if (quoteIndex >= 0) {
        var quote = value.charAt(quoteIndex);
        if (value.indexOf(quote, quoteIndex + 1) < 0) {
          do {
            i += 1;
          } while (i < tokens.length && tokens[i].indexOf(quote) < 0);
          if (i >= tokens.length) return { malformed: true };
        }
      }
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
  if (sub.malformed) return true;
  var command = sub.command;
  var rest = sub.rest;

  // Declared permanent hard blocks in apex-governance that this guard did not actually enforce
  // until 2026-07-14. They were prose, not mechanism.
  if (command === 'merge') {
    // `git merge --abort` / `--quit` are recovery, not a merge.
    return rest.indexOf('--abort') < 0 && rest.indexOf('--quit') < 0;
  }

  if (command === 'branch') {
    return rest.some(function(t) {
      return t === '-d' || t === '-D' || t === '--delete' || t === '-dr' || t === '-Dr';
    });
  }

  if (command === 'reset') {
    return rest.indexOf('--hard') >= 0;
  }

  if (command === 'checkout') {
    return rest.indexOf('--') >= 0 || rest.some(function(t) {
      if (t === '--force') return true;
      return t.startsWith('-') && !t.startsWith('--') && t.slice(1).indexOf('f') >= 0;
    });
  }

  if (command === 'restore') {
    var staged = false;
    var worktree = false;
    var sourceValue = false;
    for (var restoreIndex = 0; restoreIndex < rest.length; restoreIndex++) {
      var restoreArg = rest[restoreIndex];
      if (restoreArg === '--') break;
      // Shell parsing leaves quote placeholders, whose contents may hide mode switches.
      if (/['"]/.test(restoreArg)) return true;
      // Raw shell escapes, expansions, and splats can hide mode switches or source values.
      if (/[\\$`]/.test(restoreArg) || restoreArg.charAt(0) === '@') return true;
      if (sourceValue) {
        sourceValue = false;
        continue;
      }

      var negated = restoreArg.indexOf('--no-') === 0;
      var restoreOption = negated ? '--' + restoreArg.slice(5) : restoreArg;
      if (/^--w(o(r(k(t(r(e(e)?)?)?)?)?)?)?$/.test(restoreOption)) {
        worktree = !negated;
      } else if (/^--st(a(g(e(d)?)?)?)?$/.test(restoreOption)) {
        staged = !negated;
      } else if (/^--so(u(r(c(e)?)?)?)?(=|$)/.test(restoreArg)) {
        sourceValue = restoreArg.indexOf('=') < 0;
      } else if (/^-[^-]/.test(restoreArg)) {
        for (var restoreChar = 1; restoreChar < restoreArg.length; restoreChar++) {
          var restoreFlag = restoreArg.charAt(restoreChar);
          if (restoreFlag === 's') {
            // Everything after -s is its inline source value, not another switch.
            sourceValue = restoreChar === restoreArg.length - 1;
            break;
          }
          if (restoreFlag === 'S') staged = true;
          if (restoreFlag === 'W') worktree = true;
        }
      }
    }
    return worktree || !staged;
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
        plusRefspecForce = true;
        var refNoPlus = t.slice(1);
        var ci = refNoPlus.indexOf(':');
        var dst = (ci >= 0 ? refNoPlus.slice(ci + 1) : refNoPlus).replace(/^refs\/heads\//, '');
        if (dst === 'main' || dst === 'master') mainOrMaster = true;
      } else if (!t.startsWith('-')) {
        var colonIdx = t.indexOf(':');
        var target = (colonIdx >= 0 ? t.slice(colonIdx + 1) : t).replace(/^refs\/heads\//, '');
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

function isDestructiveBash(command, depth) {
  depth = depth || 0;
  var raw = String(command || '');
  var flattened = explodeSubshells(stripQuotedStrings(raw));
  if (DESTRUCTIVE_SQL_DD.test(flattened)) return true;

  var segments = splitCommandSegments(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    if (DESTRUCTIVE_SQL_DD.test(stripQuotedStrings(segment))) return true;

    var tokens = unwrapTransparentRunners(tokenize(segment));
    if (isDestructiveRm(tokens)) return true;
    if (isDestructivePowerShellRemove(tokens)) return true;
    if (isDestructiveCmdDelete(tokens)) return true;
    if (isClearContent(tokens)) return true;
    if (isDestructiveGit(tokens)) return true;
    if (isDestructiveDd(tokens)) return true;
  }

  if (isDestructiveCarrier(raw, segments, depth)) return true;

  // Quoted-SQL check, on the RAW command.
  //
  // This guard was dead until 2026-07-14. DESTRUCTIVE_SQL_DD was only ever tested against
  // stripQuotedStrings(...) output -- and splitCommandSegments() strips quotes before it segments --
  // so `psql -c "<statement>"`, which is how every SQL client is actually invoked, was never seen.
  // apex-governance declared these permanent hard blocks; the mechanism enforced none of them.
  //
  // Gate on the command heads so that READING about a statement stays legal (`grep`, `cat`, `echo`,
  // `git log -S`). If any head could actually execute it, test the raw string.
  var executes = segments.some(function(seg) {
    var tk = unwrapTransparentRunners(tokenize(seg));
    return tk.length > 0 && !READONLY_HEADS.has(commandBasename(tk[0]));
  });
  if (executes && DESTRUCTIVE_SQL_DD.test(raw)) return true;

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

// The AFK-only helpers (isAfkTarget / isCriticalPath / isAfkFlagWrite / SAFE_AFK_COMMANDS /
// isSafeAfkBash and their private support functions) were removed 2026-07-14.
//
// They existed solely for the `!afk` permission gate, which was reverted (ADR-033 Reversal) --
// after that, nothing called them. isCriticalPath also carried a real bug: it substring-matched
// "auth" inside "author", so any path containing the word "author" was treated as auth code.
// Dead code in a safety library is worse than no code: it looks like a control and enforces
// nothing. The two checks worth keeping -- isExfiltrationBash and isRemoteCodeExec -- were
// stranded in here too, reachable only from isSafeAfkBash; they are now wired into the live
// destructive-command-guard.

module.exports = {
  isDestructiveBash: isDestructiveBash,
  isReadOnlyGitIntrospection: isReadOnlyGitIntrospection,
  isExfiltrationBash: isExfiltrationBash,
  isRemoteCodeExec: isRemoteCodeExec,
  // Shared shell-parsing primitives. Exported so a second guard does not grow a fourth private
  // copy of quote/segment handling -- divergent copies are how the SQL never-list ended up
  // testing against the wrong side of the quote-stripping and never matching a single statement.
  splitCommandSegments: splitCommandSegments,
  tokenize: tokenize,
  commandBasename: commandBasename
};
