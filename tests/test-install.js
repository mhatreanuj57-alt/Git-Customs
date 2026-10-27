'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const { COMMANDS } = require('../lib/commands');
const { version } = require('../package.json');
const npmCli = path.join(
  path.dirname(process.execPath),
  'node_modules',
  'npm',
  'bin',
  'npm-cli.js'
);

let passed = 0;
let tempRoot = '';

function pass(name) {
  passed += 1;
  process.stdout.write(`PASS ${name}\n`);
}

function runNpm(args) {
  if (fs.existsSync(npmCli)) {
    return spawnSync(process.execPath, [npmCli, ...args], {
      cwd: root,
      encoding: 'utf8',
      windowsHide: true
    });
  }

  return spawnSync('npm', args, {
    cwd: root,
    encoding: 'utf8',
    shell: true,
    windowsHide: true
  });
}

function failResult(label, result) {
  return (
    `${label} exited ${result.status}\n` +
    `stdout:\n${result.stdout || ''}\n` +
    `stderr:\n${result.stderr || ''}`
  );
}

function expectSuccess(label, result) {
  if (result.error) {
    throw new Error(`${label} failed to start: ${result.error.message}`);
  }
  assert.strictEqual(result.status, 0, failResult(label, result));
}

function runInstalled(command, args, env, cwd) {
  return spawnSync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    windowsHide: true
  });
}

function runCmdFile(file, args, env, cwd) {
  return spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/c', 'call', file, ...args], {
    cwd,
    env,
    encoding: 'utf8',
    windowsHide: true
  });
}

function runGit(args, cwd, env) {
  const result = runInstalled('git', args, env, cwd);
  expectSuccess(`git ${args.join(' ')}`, result);
  return result;
}

try {
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'git-customs-install-'));
  const packDir = path.join(tempRoot, 'pack');
  const prefix = path.join(tempRoot, 'prefix');
  fs.mkdirSync(packDir, { recursive: true });

  const packed = runNpm([
    'pack',
    '--json',
    '--pack-destination',
    packDir,
    '--loglevel=error'
  ]);
  expectSuccess('npm pack', packed);

  const packInfo = JSON.parse(packed.stdout)[0];
  const tarball = path.join(packDir, packInfo.filename);
  const packedFiles = packInfo.files.map((file) => file.path);

  assert.ok(fs.existsSync(tarball), `tarball was not created: ${tarball}`);
  assert.ok(packedFiles.includes('bin/cli.js'), 'bin/cli.js is missing from the tarball');
  assert.ok(
    packedFiles.includes('scripts/git-work.ps1'),
    'PowerShell command scripts are missing from the tarball'
  );
  assert.ok(
    !packedFiles.some((file) => file.startsWith('tests/')),
    'test files must not be included in the published tarball'
  );
  pass('npm pack contains runtime files and excludes tests');

  const installed = runNpm([
    'install',
    '-g',
    '--prefix',
    prefix,
    tarball,
    '--no-audit',
    '--no-fund',
    '--loglevel=error'
  ]);
  expectSuccess('npm install -g --prefix', installed);

  const env = { ...process.env };
  delete env.GIT_CUSTOMS_TEST_BIN;
  delete env.GIT_CUSTOMS_TEST_SCRIPTS;
  const pathKey = Object.keys(env).find((key) => key.toUpperCase() === 'PATH');
  env[pathKey] = `${prefix}${path.delimiter}${env[pathKey]}`;

  for (const command of COMMANDS) {
    assert.ok(
      fs.existsSync(path.join(prefix, command.bin)),
      `npm did not create the extensionless shim ${command.bin}`
    );

    const result = runGit([command.name, '-h'], tempRoot, env);
    assert.match(
      result.stdout,
      new RegExp(`Usage: git ${command.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`),
      `${command.bin} did not show its help output`
    );
  }
  pass('all installed Git commands resolve and run');

  const cliVersion = runCmdFile(
    path.join(prefix, 'git-customs.cmd'),
    ['--version'],
    env,
    tempRoot
  );
  expectSuccess('git-customs --version', cliVersion);
  assert.strictEqual(cliVersion.stdout.trim(), version);

  const aliasVersion = runCmdFile(
    path.join(prefix, 'anuj-custom-git-command-list.cmd'),
    ['--version'],
    env,
    tempRoot
  );
  expectSuccess('anuj-custom-git-command-list --version', aliasVersion);
  assert.strictEqual(aliasVersion.stdout.trim(), version);

  const dispatched = runCmdFile(
    path.join(prefix, 'git-customs.cmd'),
    ['run', 'suggest', '-h'],
    env,
    tempRoot
  );
  expectSuccess('git-customs run suggest -h', dispatched);
  assert.match(dispatched.stdout, /Usage: git suggest/);
  pass('installed CLI aliases and run dispatch work');

  const repo = path.join(tempRoot, 'repo');
  const origin = path.join(tempRoot, 'origin.git');
  fs.mkdirSync(repo);
  runGit(['init', '-b', 'main'], repo, env);
  runGit(['config', 'user.name', 'Package Test'], repo, env);
  runGit(['config', 'user.email', 'package-test@example.com'], repo, env);
  runGit(['config', 'commit.gpgsign', 'false'], repo, env);
  fs.writeFileSync(path.join(repo, 'README.md'), '# package install test\n');
  runGit(['add', 'README.md'], repo, env);
  runGit(['commit', '-m', 'initial commit'], repo, env);
  runGit(['init', '--bare', origin], repo, env);
  runGit(['remote', 'add', 'origin', origin], repo, env);
  runGit(['push', '-u', 'origin', 'main'], repo, env);

  const suggest = runGit(['suggest'], repo, env);
  assert.match(suggest.stdout, /up to date/i);
  const autopush = runGit(['autopush'], repo, env);
  assert.match(autopush.stdout, /up to date|nothing to push/i);
  pass('installed suggest and autopush execute end to end');

  fs.rmSync(tempRoot, { recursive: true, force: true });
  process.stdout.write(`\nInstall tests: ${passed} passed.\n`);
} catch (error) {
  if (tempRoot) {
    process.stderr.write(`Install test workspace preserved at: ${tempRoot}\n`);
  }
  throw error;
}
