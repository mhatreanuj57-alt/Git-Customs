'use strict';

const assert = require('node:assert');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const { COMMANDS } = require('../lib/commands');
const { version } = require('../package.json');

let passed = 0;

function runNode(args) {
  return spawnSync(process.execPath, args, {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
    windowsHide: true
  });
}

function pass(name) {
  passed += 1;
  process.stdout.write(`PASS ${name}\n`);
}

function expectSuccess(result, label) {
  assert.strictEqual(
    result.status,
    0,
    `${label} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
  );
}

const help = runNode(['bin/cli.js', '--help']);
expectSuccess(help, 'git-customs --help');
assert.match(help.stdout, /Usage:/);
for (const command of COMMANDS) {
  assert.match(help.stdout, new RegExp(`\\b${command.name}\\b`));
}
pass('main help lists every command');

const versionResult = runNode(['bin/cli.js', '--version']);
expectSuccess(versionResult, 'git-customs --version');
assert.strictEqual(versionResult.stdout.trim(), version);
pass('version matches package metadata');

const list = runNode(['bin/cli.js', 'list']);
expectSuccess(list, 'git-customs list');
assert.deepStrictEqual(
  list.stdout.trim().split(/\r?\n/),
  COMMANDS.map((command) => command.name)
);
pass('list is stable and complete');

const unknown = runNode(['bin/cli.js', 'not-a-command']);
assert.strictEqual(unknown.status, 1);
assert.match(unknown.stderr, /unknown command/i);
pass('unknown command fails cleanly');

const missingRunTarget = runNode(['bin/cli.js', 'run']);
assert.strictEqual(missingRunTarget.status, 1);
assert.match(missingRunTarget.stderr, /requires a command name/i);
pass('incomplete run command fails cleanly');

for (const command of COMMANDS) {
  const binPath = path.join('bin', `git-${command.name}.js`);
  const direct = runNode([binPath, '-h']);
  expectSuccess(direct, command.bin);
  assert.match(
    direct.stdout,
    new RegExp(`Usage: git ${command.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`)
  );

  const throughCli = runNode(['bin/cli.js', 'run', command.name, '-h']);
  expectSuccess(throughCli, `git-customs run ${command.name}`);
  assert.match(throughCli.stdout, /Usage: git /);
}
pass('all command entry points and run dispatch return help');

const convenience = runNode(['bin/cli.js', 'work', '-h']);
expectSuccess(convenience, 'git-customs work -h');
assert.match(convenience.stdout, /Usage: git work/);
pass('direct command form is supported');

process.stdout.write(`\nCLI tests: ${passed} passed.\n`);
