#!/usr/bin/env node
/**
 * gate-credential-watchdog.js — probe gate CI credentials before PRs pile up.
 *
 * [wo:gate-secret-watchdog]: validates AUTOMATION_ANTHROPIC_API_KEY, OPENAI_KEY,
 * and CLAUDE_PAT with auth-centric HTTP probes. Reports credential names +
 * verdicts only — never values. Exit 1 when any credential is INVALID or
 * MISCONFIGURED; exit 0 when all are VALID and/or UNREACHABLE only.
 *
 * Usage:
 *   node .claude/scripts/gate-credential-watchdog.js [--json]
 */

'use strict';

const ANTHROPIC_VERSION = '2023-06-01';
const HAIKU_MODEL = 'claude-3-5-haiku-20241022';
const ISSUE_MARKER = '<!-- gate-credential-watchdog -->';
const ISSUE_LABEL = 'credential-watchdog';

// AUTOMATION_ANTHROPIC_API_KEY was retired 2026-07-14: the gate reviewers run on
// the company Claude subscription OAuth token (REVIEWER_SUB_OAUTH_TOKEN), so no
// workflow consumes that API key anymore. Probing it would permanently alert on a
// key that is dead on purpose.
const CREDENTIAL_NAMES = Object.freeze([
  process.env.OPENAI_API_KEY ? 'OPENAI_API_KEY' : 'OPENAI_KEY',
  'CLAUDE_PAT',
]);

function classifyAnthropicStatus(status) {
  if (status === 401 || status === 403) return 'INVALID';
  if (status >= 200 && status < 300) return 'VALID';
  if (status === 400 || status === 404 || status === 429) return 'VALID';
  if (status >= 500) return 'UNREACHABLE';
  return 'UNREACHABLE';
}

function classifyOpenAiStatus(status) {
  if (status === 401 || status === 403) return 'INVALID';
  if (status >= 200 && status < 300) return 'VALID';
  if (status === 429) return 'VALID';
  if (status >= 500) return 'UNREACHABLE';
  return 'UNREACHABLE';
}

function classifyGithubPatStatus(status) {
  return classifyOpenAiStatus(status);
}

function classifyEnvValue(value) {
  if (value == null || String(value).trim() === '') return 'MISCONFIGURED';
  return null;
}

function computeExitCode(results) {
  const alerting = results.some(
    (r) => r.verdict === 'INVALID' || r.verdict === 'MISCONFIGURED'
  );
  return alerting ? 1 : 0;
}

function buildAlertIssueTitle(credentialName) {
  return `⚠️ gate credential invalid — ${credentialName}`;
}

function buildIssueBody(results, { runUrl = '', checkedAt = new Date().toISOString() } = {}) {
  const lines = [
    ISSUE_MARKER,
    'One or more gate CI credentials failed validation.',
    '',
    `Checked at: ${checkedAt}`,
  ];
  if (runUrl) {
    lines.push(`Workflow run: ${runUrl}`);
  }
  lines.push('', '| Credential | Verdict |', '| --- | --- |');
  for (const row of results) {
    lines.push(`| ${row.name} | ${row.verdict} |`);
  }
  lines.push(
    '',
    '_Rotate or restore the invalid credential in GitHub repo/environment secrets, then re-run the watchdog._'
  );
  return lines.join('\n');
}

function containsSecretLeak(text, secret) {
  if (!secret) return false;
  const haystack = String(text);
  if (haystack.includes(secret)) return true;
  if (secret.length >= 8) {
    for (let i = 0; i <= secret.length - 8; i += 1) {
      if (haystack.includes(secret.slice(i, i + 8))) return true;
    }
  }
  return false;
}

function collectConfiguredSecrets(env) {
  return CREDENTIAL_NAMES.map((name) => env[name]).filter(Boolean);
}

function assertNoSecretLeak(text, secrets) {
  for (const secret of secrets) {
    if (containsSecretLeak(text, secret)) {
      throw new Error('credential value leaked into output');
    }
  }
}

async function probeAnthropic(apiKey, fetchImpl = fetch) {
  try {
    const response = await fetchImpl('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': ANTHROPIC_VERSION,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: HAIKU_MODEL,
        max_tokens: 1,
        messages: [{ role: 'user', content: 'ping' }],
      }),
    });
    return classifyAnthropicStatus(response.status);
  } catch {
    return 'UNREACHABLE';
  }
}

async function probeOpenAi(apiKey, fetchImpl = fetch) {
  try {
    const response = await fetchImpl('https://api.openai.com/v1/models', {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${apiKey}`,
      },
    });
    return classifyOpenAiStatus(response.status);
  } catch {
    return 'UNREACHABLE';
  }
}

async function probeGithubPat(token, fetchImpl = fetch) {
  try {
    const response = await fetchImpl('https://api.github.com/user', {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
    return classifyGithubPatStatus(response.status);
  } catch {
    return 'UNREACHABLE';
  }
}

async function probeCredential(name, env, fetchImpl = fetch) {
  const value = env[name];
  const misconfigured = classifyEnvValue(value);
  if (misconfigured) {
    return { name, verdict: misconfigured };
  }

  let verdict;
  switch (name) {
    case 'ANTHROPIC_API_KEY':
    case 'AUTOMATION_ANTHROPIC_API_KEY':
      verdict = await probeAnthropic(value, fetchImpl);
      break;
    case 'OPENAI_API_KEY':
    case 'OPENAI_KEY':
      verdict = await probeOpenAi(value, fetchImpl);
      break;
    case 'CLAUDE_PAT':
      verdict = await probeGithubPat(value, fetchImpl);
      break;
    default:
      verdict = 'MISCONFIGURED';
  }
  return { name, verdict };
}

async function runWatchdog(env = process.env, fetchImpl = fetch) {
  const results = [];
  for (const name of CREDENTIAL_NAMES) {
    results.push(await probeCredential(name, env, fetchImpl));
  }
  return results;
}

function formatReport(results) {
  return results.map((row) => `${row.name}: ${row.verdict}`).join('\n');
}

function invalidResults(results) {
  return results.filter(
    (row) => row.verdict === 'INVALID' || row.verdict === 'MISCONFIGURED'
  );
}

function isAllClear(results) {
  return invalidResults(results).length === 0;
}

async function main() {
  const jsonMode = process.argv.includes('--json');
  const results = await runWatchdog(process.env, globalThis.fetch);
  const exitCode = computeExitCode(results);
  const secrets = collectConfiguredSecrets(process.env);

  const report = formatReport(results);
  assertNoSecretLeak(report, secrets);

  if (jsonMode) {
    const payload = JSON.stringify({ results, exitCode }, null, 2);
    assertNoSecretLeak(payload, secrets);
    console.log(payload);
  } else {
    console.log(report);
  }

  process.exit(exitCode);
}

module.exports = {
  ANTHROPIC_VERSION,
  HAIKU_MODEL,
  ISSUE_MARKER,
  ISSUE_LABEL,
  CREDENTIAL_NAMES,
  classifyAnthropicStatus,
  classifyOpenAiStatus,
  classifyGithubPatStatus,
  classifyEnvValue,
  computeExitCode,
  buildAlertIssueTitle,
  buildIssueBody,
  containsSecretLeak,
  collectConfiguredSecrets,
  assertNoSecretLeak,
  probeAnthropic,
  probeOpenAi,
  probeGithubPat,
  probeCredential,
  runWatchdog,
  formatReport,
  invalidResults,
  isAllClear,
};

if (require.main === module) {
  main().catch((err) => {
    console.error(`gate-credential-watchdog: ${err.message}`);
    process.exit(2);
  });
}
