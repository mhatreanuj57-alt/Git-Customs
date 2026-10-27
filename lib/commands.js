'use strict';

const COMMANDS = Object.freeze([
  {
    name: 'action-workflow',
    bin: 'git-action-workflow',
    script: 'git-action-workflow.ps1',
    summary: 'Create, validate, inspect, watch, retry, and read logs for GitHub Actions workflows.',
    usage: 'git action-workflow <init|validate|status|watch|logs|retry> [options]'
  },
  {
    name: 'action-fix',
    bin: 'git-action-fix',
    script: 'git-action-fix.ps1',
    summary: 'Diagnose a GitHub Actions run and apply guarded workflow or repository fixes.',
    usage: 'git action-fix [--run <id>] [options]'
  },
  {
    name: 'suggest',
    bin: 'git-suggest',
    script: 'git-suggest.ps1',
    summary: 'Preview safe per-file add, commit, and push commands without changing the repository.',
    usage: 'git suggest'
  },
  {
    name: 'autopush',
    bin: 'git-autopush',
    script: 'git-autopush.ps1',
    summary: 'Create and push one commit per changed file, stopping at the first failure.',
    usage: 'git autopush'
  },
  {
    name: 'work',
    bin: 'git-work',
    script: 'git-work.ps1',
    summary: 'Track named work items and generate branch or pull-request suggestions.',
    usage: 'git work <list|add|remove|prune> [options]'
  },
  {
    name: 'doctor',
    bin: 'git-doctor',
    script: 'git-doctor.ps1',
    summary: 'Check repository health, Git identity, remotes, workflows, and optional GitHub metadata.',
    usage: 'git doctor [--no-github] [--strict]'
  },
  {
    name: 'security-check',
    bin: 'git-security-check',
    script: 'git-security-check.ps1',
    summary: 'Scan staged changes and workflow files for leaked secrets and unsafe workflow settings.',
    usage: 'git security-check [--staged] [--strict] [--secrets-only|--workflows-only]'
  },
  {
    name: 'pr-flow',
    bin: 'git-pr-flow',
    script: 'git-pr-flow.ps1',
    summary: 'Inspect pull-request readiness, create a PR, and check CI status.',
    usage: 'git pr-flow <status|create|checks> [options]'
  },
  {
    name: 'release',
    bin: 'git-release',
    script: 'git-release.ps1',
    summary: 'Inspect release readiness, create tags, and run guarded release publishing.',
    usage: 'git release <status|tag|publish> [options]'
  }
]);

const BY_NAME = new Map();

for (const command of COMMANDS) {
  BY_NAME.set(command.name, command);
  BY_NAME.set(command.bin, command);
}

function getCommand(name) {
  if (!name) {
    return null;
  }

  return BY_NAME.get(String(name).toLowerCase()) || null;
}

function helpText(version) {
  const lines = [
    `anuj-custom-git-command-list ${version}`,
    '',
    'A collection of tested Git extension commands for Windows.',
    '',
    'Usage:',
    '  git-customs [command] [options]',
    '  git-customs run <command> [options]',
    '  git <command> [options]',
    '',
    'Commands:'
  ];

  const width = Math.max(...COMMANDS.map((command) => command.name.length));
  for (const command of COMMANDS) {
    lines.push(`  ${command.name.padEnd(width)}  ${command.summary}`);
  }

  lines.push(
    '',
    'Global options:',
    '  -h, --help       Show this help.',
    '  -v, --version    Show the package version.',
    '  list             List command names.',
    '',
    'Examples:',
    '  git action-workflow status',
    '  git suggest',
    '  git doctor --strict',
    '  git-customs run security-check --staged',
    '',
    'Run `git <command> -h` for full command options.'
  );

  return `${lines.join('\n')}\n`;
}

module.exports = { COMMANDS, getCommand, helpText };
