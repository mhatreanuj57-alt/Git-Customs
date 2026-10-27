'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCRIPTS_DIR = path.join(__dirname, '..', 'scripts');

function fail(message) {
  process.stderr.write(`git-customs: ${message}\n`);
  process.exit(1);
}

function getPowerShell() {
  const configured = process.env.GIT_CUSTOMS_POWERSHELL;

  if (configured && configured.trim()) {
    return configured.trim();
  }

  if (process.platform === 'win32') {
    return 'powershell.exe';
  }

  return null;
}

function runScript(command, args) {
  if (process.platform !== 'win32') {
    fail('these commands require Windows and Windows PowerShell.');
  }

  if (!/^[a-z0-9][a-z0-9-]*$/i.test(command)) {
    fail(`invalid command name: ${command}`);
  }

  const scriptName = `git-${command.replace(/^git-/, '')}.ps1`;
  const scriptPath = path.join(SCRIPTS_DIR, scriptName);

  if (!fs.existsSync(scriptPath)) {
    fail(`missing command script: ${scriptPath}`);
  }

  const powerShell = getPowerShell();
  const result = spawnSync(
    powerShell,
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args],
    { stdio: 'inherit', windowsHide: false }
  );

  if (result.error) {
    if (result.error.code === 'ENOENT') {
      fail(
        `cannot find PowerShell executable "${powerShell}". ` +
          'Install Windows PowerShell 5.1 or set GIT_CUSTOMS_POWERSHELL.'
      );
    }

    fail(`failed to start PowerShell: ${result.error.message}`);
  }

  if (typeof result.status !== 'number') {
    fail(`PowerShell terminated unexpectedly${result.signal ? ` (${result.signal})` : ''}.`);
  }

  process.exit(result.status);
}

module.exports = { runScript };
