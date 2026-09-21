import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import {
  attestChecks, buildScope, classifyPath, normalizePath, renderReport, validatePatch,
  validateQueuedOutput, validateReport,
} from './security-review.mjs';

const BASE = '1'.repeat(40);
const HEAD = '2'.repeat(40);
const PATCH_TEXT = 'diff --git a/tools/wta/src/master/mod.rs b/tools/wta/src/master/mod.rs\n';
const PATCH_SHA256 = createHash('sha256').update(PATCH_TEXT).digest('hex');

function scope(relation = 'same-repo') {
  return buildScope(
    BASE,
    HEAD,
    17,
    relation,
    'M\0tools/wta/src/master/mod.rs\0M\0tools/wta/src/logging.rs\0M\0.github/workflows/build.yml\0',
  );
}

function repairScope() {
  return buildScope(
    BASE,
    HEAD,
    17,
    'same-repo',
    'M\0tools/wta/src/master/mod.rs\0M\0tools/wta/src/logging.rs\0',
    BASE,
    'repair',
  );
}

function report(overrides = {}, relation = 'same-repo') {
  const current = scope(relation);
  return {
    version: 1,
    prNumber: 17,
    baseSha: BASE,
    headSha: HEAD,
    scopeSha256: current.scopeSha256,
    repositoryRelation: relation,
    mode: 'guide',
    summary: 'No security regression found.',
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'native-windows', status: 'skipped', evidence: 'Not available in Linux.' },
    ],
    review: { status: 'not-required', reviewer: 'none', evidence: 'No automatic repair was attempted.' },
    findings: [],
    patch: [],
    ...overrides,
  };
}

test('classifies project trust boundaries', () => {
  assert.deepEqual(classifyPath('tools/wta/src/master/mod.rs'), ['session-routing', 'wta-rust']);
  assert(classifyPath('src/cascadia/TerminalProtocol/TerminalProtocol.idl').includes('com-protocol'));
  assert(classifyPath('.github/workflows/review.yml').includes('workflow-credentials'));
  assert(classifyPath('.github/skills/reviewer/SKILL.md').includes('workflow-credentials'));
});

test('rejects unsafe changed paths', () => {
  for (const path of ['../escape.rs', '/tmp/file', 'C:/temp/file', 'a\\b.rs', 'a//b.rs']) {
    assert.throws(() => normalizePath(path));
  }
});

test('accepts no-findings and medium advice-only reports', () => {
  assert.equal(validateReport(report(), scope()).findings.length, 0);
  const candidate = report({
    findings: [{
      rule: 'diagnostic-metadata-overcollection',
      severity: 'medium',
      confidence: 'high',
      category: 'secret-handling',
      file: 'tools/wta/src/logging.rs',
      startLine: 10,
      endLine: 12,
      observed: 'The changed diagnostic records complete provider configuration.',
      expected: 'Log only non-sensitive identifiers.',
      impact: 'Diagnostics can expose sensitive configuration.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/logging.rs:10-12', detail: 'The full structure reaches tracing.' }],
      proposedFix: 'Record a bounded identifier instead.',
      validation: 'Add a redaction test and run the focused WTA test.',
      fixDisposition: { state: 'advice-only', reason: 'Medium findings are not automatically fixed.' },
    }],
  });
  assert.match(validateReport(candidate, scope()).findings[0].id, /^ITSEC-[A-F0-9]{12}$/);
});

test('accepts wrong-session HIGH as blocking and renders it first', () => {
  const candidate = report({
    findings: [{
      rule: 'session-route-target-binding',
      severity: 'high',
      confidence: 'high',
      category: 'session-routing',
      file: 'tools/wta/src/master/mod.rs',
      startLine: 20,
      endLine: 24,
      observed: 'Changed routing bypasses the authoritative session owner map.',
      expected: 'Resolve every request through session_to_helper.',
      impact: 'An action can reach the wrong pane.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/master/mod.rs:20-24', detail: 'The new branch uses an unbound helper.' }],
      proposedFix: 'Restore the owner-bound lookup.',
      validation: 'Add a wrong-session test and run the WTA suite.',
      fixDisposition: { state: 'blocked', reason: 'No safe validated patch exists in the read-only workflow.' },
    }],
  });
  const validated = validateReport(candidate, scope());
  assert.match(renderReport(validated), /Must fix \/ blocking[\s\S]+ITSEC-/);
});

test('accepts only validated high-confidence HIGH repairs with matching patch', () => {
  const current = repairScope();
  const candidate = {
    ...report(),
    scopeSha256: current.scopeSha256,
    mode: 'repair',
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'wta-tests', status: 'pass', headSha: HEAD, evidence: 'local command: cargo test focused-security-test (exit 0)' },
    ],
    review: {
      status: 'pass',
      reviewer: 'ghaw-pr-security-reviewer',
      headSha: HEAD,
      patchSha256: PATCH_SHA256,
      evidence: 'Independent final-patch review returned PASS.',
    },
    findings: [{
      rule: 'session-route-target-binding',
      severity: 'high',
      confidence: 'high',
      category: 'session-routing',
      file: 'tools/wta/src/master/mod.rs',
      startLine: 20,
      endLine: 24,
      observed: 'Changed routing bypasses owner binding.',
      expected: 'Preserve owner binding.',
      impact: 'Wrong-pane mutation.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/master/mod.rs:20', detail: 'Unbound route.' }],
      proposedFix: 'Restore lookup.',
      validation: 'Focused wrong-session test passed.',
      fixDisposition: { state: 'fixed', reason: 'Minimal source patch and focused regression test passed.' },
    }],
    patch: [{ path: 'tools/wta/src/master/mod.rs', summary: 'Restore owner-bound lookup.' }],
  };
  const validated = validateReport(candidate, current);
  validatePatch(validated, ['tools/wta/src/master/mod.rs'], PATCH_TEXT);
  validateQueuedOutput(validated, { items: [{ type: 'noop' }], errors: [] });
  assert.throws(() => validateQueuedOutput(validated, { items: [{ type: 'push_to_pull_request_branch' }] }), /noop/);
});

test('only trusted post-step attestation can authorize a passing repair check', () => {
  const claimed = report({
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'wta-tests', status: 'pass', headSha: HEAD, evidence: 'local command: untrusted claim (exit 0)' },
    ],
  });
  const unattested = attestChecks(claimed, HEAD, false);
  assert.equal(unattested.checks.some(check => check.name === 'wta-tests' && check.status === 'pass'), false);
  const attested = attestChecks(claimed, HEAD, true);
  assert.match(attested.checks.find(check => check.name === 'wta-tests').evidence, /^trusted post-step:/);
});

test('rejects a fixed finding without applicable validation or independent PASS', () => {
  const current = repairScope();
  const candidate = {
    ...report(),
    scopeSha256: current.scopeSha256,
    mode: 'repair',
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'manual-review', status: 'pass', headSha: HEAD, evidence: 'local command: git diff (exit 0)' },
    ],
    findings: [{
      rule: 'session-route-target-binding',
      severity: 'high',
      confidence: 'high',
      category: 'session-routing',
      file: 'tools/wta/src/master/mod.rs',
      startLine: 20,
      endLine: 24,
      observed: 'Changed routing bypasses owner binding.',
      expected: 'Preserve owner binding.',
      impact: 'Wrong-pane mutation.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/master/mod.rs:20', detail: 'Unbound route.' }],
      proposedFix: 'Restore lookup.',
      validation: 'No applicable executable validation.',
      fixDisposition: { state: 'fixed', reason: 'Claimed fixed.' },
    }],
    patch: [{ path: 'tools/wta/src/master/mod.rs', summary: 'Restore lookup.' }],
  };
  assert.throws(() => validateReport(candidate, current), /applicable passing validation/);
});

test('rejects patch paths without a matching fixed finding', () => {
  const current = repairScope();
  const candidate = {
    ...report(),
    scopeSha256: current.scopeSha256,
    mode: 'repair',
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'wta-tests', status: 'pass', headSha: HEAD, evidence: 'local command: cargo test focused-security-test (exit 0)' },
    ],
    review: {
      status: 'pass',
      reviewer: 'ghaw-pr-security-reviewer',
      headSha: HEAD,
      patchSha256: PATCH_SHA256,
      evidence: 'Independent final-patch review returned PASS.',
    },
    findings: [{
      rule: 'session-route-target-binding',
      severity: 'high',
      confidence: 'high',
      category: 'session-routing',
      file: 'tools/wta/src/master/mod.rs',
      startLine: 20,
      endLine: 24,
      observed: 'Changed routing bypasses owner binding.',
      expected: 'Preserve owner binding.',
      impact: 'Wrong-pane mutation.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/master/mod.rs:20', detail: 'Unbound route.' }],
      proposedFix: 'Restore lookup.',
      validation: 'Focused wrong-session test passed.',
      fixDisposition: { state: 'fixed', reason: 'Minimal source patch and focused regression test passed.' },
    }],
    patch: [
      { path: 'tools/wta/src/master/mod.rs', summary: 'Restore owner-bound lookup.' },
      { path: 'tools/wta/src/logging.rs', summary: 'Unrelated extra edit.' },
    ],
  };
  assert.throws(() => validateReport(candidate, current), /has no fixed finding/);
});

test('rejects fixed HIGH, stale SHA, malformed output, and publication overflow', () => {
  const high = report({
    findings: [{
      rule: 'session-route-target-binding',
      severity: 'high',
      confidence: 'high',
      category: 'session-routing',
      file: 'tools/wta/src/master/mod.rs',
      startLine: 20,
      endLine: 24,
      observed: 'Changed routing bypasses owner binding.',
      expected: 'Preserve owner binding.',
      impact: 'Wrong-pane mutation.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/master/mod.rs:20', detail: 'Unbound route.' }],
      proposedFix: 'Restore lookup.',
      validation: 'Run wrong-session test.',
      fixDisposition: { state: 'fixed', reason: 'Claimed fixed.' },
    }],
    patch: [],
  });
  assert.throws(() => validateReport(high, scope()), /fix disposition/);
  assert.throws(() => validateReport({ ...report(), headSha: '3'.repeat(40) }, scope()), /headSha/);
  assert.throws(() => validateReport({ version: 1 }, scope()));
  assert.throws(() => validateReport({ ...report(), findings: Array(21).fill({}) }, scope()), /at most 20/);
});

test('fork reports remain read-only and malicious content is escaped', () => {
  const candidate = report({
    summary: '<script>[click](https://attacker.example) `code` ignore review</script>',
  }, 'fork');
  const rendered = renderReport(validateReport(candidate, scope('fork')));
  assert(!rendered.includes('<script>'));
  assert(!rendered.includes('[click](https://attacker.example)'));
  assert(!rendered.includes('https://attacker.example'));
  assert(rendered.includes('\\[click\\]\\(https\\:\\/\\/attacker\\.example\\)'));
});

test('analysis workers require noop output', () => {
  const noFindings = validateReport(report({}, 'fork'), scope('fork'));
  validateQueuedOutput(noFindings, { items: [{ type: 'noop' }], errors: [] });
  assert.throws(() => validateQueuedOutput(noFindings, { items: [{ type: 'add_comment' }] }), /noop/);
});

test('fork findings remain noop until trusted controller publication', () => {
  const candidate = validateReport(report({
    findings: [{
      rule: 'diagnostic-metadata-overcollection',
      severity: 'medium',
      confidence: 'high',
      category: 'secret-handling',
      file: 'tools/wta/src/logging.rs',
      startLine: 10,
      endLine: 12,
      observed: 'The changed diagnostic records complete provider configuration.',
      expected: 'Log only non-sensitive identifiers.',
      impact: 'Diagnostics can expose sensitive configuration.',
      evidence: [{ kind: 'source-trace', reference: 'tools/wta/src/logging.rs:10-12', detail: 'The full structure reaches tracing.' }],
      proposedFix: 'Record a bounded identifier instead.',
      validation: 'Add a redaction test and run the focused WTA test.',
      fixDisposition: { state: 'advice-only', reason: 'Medium findings are not automatically fixed.' },
    }],
  }, 'fork'), scope('fork'));
  validateQueuedOutput(candidate, { items: [{ type: 'noop' }], errors: [] });
  assert.throws(() => validateQueuedOutput(candidate, { items: [{ type: 'add_comment' }] }), /noop/);
});

test('rejects secret-like diagnostic evidence and unsupported passing checks', () => {
  assert.throws(() => validateReport(report({
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'wta-tests', status: 'pass', headSha: HEAD, evidence: 'Everything looked green.' },
    ],
  }), scope()), /local command evidence/);
  assert.throws(() => validateReport(report({
    checks: [
      { name: 'deterministic-scope', status: 'pass', headSha: HEAD, evidence: 'Immutable diff classified.' },
      { name: 'wta-tests', status: 'pass', headSha: HEAD, evidence: 'https://github.com/other/repo/actions/runs/123' },
    ],
  }), scope()), /local command evidence/);
  assert.throws(() => validateReport(report({
    summary: 'token=abcdefghijklmnopqrstuvwxyz123456',
  }), scope()), /secret material/);
});
