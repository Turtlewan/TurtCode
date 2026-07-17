/**
 * Shared reason-gated guard-disable contract.
 *
 * resolveDisable({ guard, disableValue, reason, subject }) recognizes exactly off, 0, false, and
 * disabled (case/whitespace normalized). Every recognized attempt appends one JSON line shaped as
 * { ts, guard, reason, honored, subject } to APEX_GUARD_AUDIT_LOG or ../guard-audit.log; subject is
 * truncated to 500 characters. A disable is honored only when reason is non-empty and that audit
 * line is written. The append deliberately uses synchronous fs.appendFileSync inside try/catch:
 * if the write throws, honored becomes false so an untraced disable fails closed before return.
 */

'use strict';

var fs = require('fs');
var path = require('path');

var DISABLE_VALUES = /^(?:off|0|false|disabled)$/;

function resolveDisable(options) {
  options = options || {};

  var disableValue = String(options.disableValue || '').trim().toLowerCase();
  if (!DISABLE_VALUES.test(disableValue)) {
    return { disabled: false };
  }

  var reason = options.reason;
  var honored = String(reason || '').trim().length > 0;
  var auditLog = process.env.APEX_GUARD_AUDIT_LOG || path.join(__dirname, '..', 'guard-audit.log');
  var record = {
    ts: new Date().toISOString(),
    guard: options.guard,
    reason: honored ? reason : null,
    honored: honored,
    subject: String(options.subject || '').slice(0, 500)
  };

  try {
    fs.appendFileSync(auditLog, JSON.stringify(record) + '\n', 'utf8');
  } catch (e) {
    honored = false;
  }

  return { disabled: honored };
}

module.exports = resolveDisable;

