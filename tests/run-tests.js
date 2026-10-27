'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const scriptsDir = path.join(root, 'scripts');
const powerShell = process.env.GIT_CUSTOMS_POWERSHELL || 'powershell.exe';

const suites = [
  ['Portable: work', 'tests/portable/run-work-tests.ps1'],
  ['Portable: doctor', 'tests/portable/run-doctor-tests.ps1'],
  ['Portable: security-check', 'tests/portable/run-security-check-tests.ps1'],
  ['Portable: pr-flow', 'tests/portable/run-pr-flow-tests.ps1'],
  ['Portable: release', 'tests/portable/run-release-tests.ps1'],
  ['Action workflow: end to end', 'tests/legacy/run-e2e-tests.ps1'],
  ['Action workflow: engine', 'tests/legacy/run-engine-tests.ps1'],
  ['Action workflow: init and validate', 'tests/legacy/run-init-validate-tests.ps1'],
  ['Action workflow: logs', 'tests/legacy/run-logs-tests.ps1'],
  ['Action workflow: retry', 'tests/legacy/run-retry-tests.ps1'],
  ['Action workflow: status', 'tests/legacy/run-status-tests.ps1'],
  ['Action workflow: watch', 'tests/legacy/run-watch-tests.ps1'],
  ['Action fix', 'tests/legacy/run-action-fix-tests.ps1'],
  ['Suggest', 'tests/suggest/run-tests.ps1'],
  ['Autopush', 'tests/autopush/run-tests.ps1']
];

const commandsOnly = process.argv.includes('--commands-only');
const noInstall = commandsOnly || process.argv.includes('--no-install');
const failures = [];

function runNode(label, script) {
  process.stdout.write(`\n=== ${label} ===\n`);
  const result = spawnSync(process.execPath, [script], {
    cwd: root,
    stdio: 'inherit',
    env: process.env,
    windowsHide: true
  });

  if (result.error) {
    failures.push(`${label}: ${result.error.message}`);
    return false;
  }
  if (result.status !== 0) {
    failures.push(`${label}: exited ${result.status}`);
    return false;
  }
  return true;
}

if (process.platform !== 'win32') {
  process.stderr.write('These commands and their tests require Windows.\n');
  process.exit(1);
}

const env = { ...process.env, GIT_CUSTOMS_TEST_BIN: scriptsDir };

for (const [label, relativePath] of suites) {
  const suitePath = path.join(root, relativePath);
  process.stdout.write(`\n=== ${label} ===\n`);

  if (!fs.existsSync(suitePath)) {
    failures.push(`${label}: missing ${relativePath}`);
    continue;
  }

  const result = spawnSync(
    powerShell,
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', suitePath],
    {
      cwd: root,
      stdio: 'inherit',
      env,
      windowsHide: true
    }
  );

  if (result.error) {
    failures.push(`${label}: ${result.error.message}`);
  } else if (result.status !== 0) {
    failures.push(`${label}: exited ${result.status}`);
  }
}

if (failures.length === 0 && !commandsOnly) {
  runNode('CLI entry points', path.join(root, 'tests', 'test-cli.js'));
}

if (failures.length === 0 && !noInstall) {
  runNode('Installed package', path.join(root, 'tests', 'test-install.js'));
}

if (failures.length > 0) {
  process.stderr.write('\nFailures:\n');
  for (const failure of failures) {
    process.stderr.write(`  - ${failure}\n`);
  }
  process.exitCode = 1;
} else {
  process.stdout.write(
    `\n${commandsOnly ? 'Command suites' : 'All tests'} passed: ${suites.length} command suites` +
      `${commandsOnly ? '' : ', CLI entry points, installed package'}.\n`
  );
}
