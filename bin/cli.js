#!/usr/bin/env node
'use strict';

const { COMMANDS, getCommand, helpText } = require('../lib/commands');
const { runScript } = require('../lib/run-command');
const { version } = require('../package.json');

const args = process.argv.slice(2);

if (args.length === 0 || ['help', '--help', '-h'].includes(args[0])) {
  process.stdout.write(helpText(version));
  process.exit(0);
}

if (['--version', '-v'].includes(args[0])) {
  process.stdout.write(`${version}\n`);
  process.exit(0);
}

if (args[0] === 'list') {
  process.stdout.write(`${COMMANDS.map((command) => command.name).join('\n')}\n`);
  process.exit(0);
}

let requested = args[0];
let rest = args.slice(1);

if (requested === 'run') {
  requested = args[1];
  rest = args.slice(2);
}

if (!requested) {
  process.stderr.write('git-customs: run requires a command name.\n');
  process.exit(1);
}

const command = getCommand(requested);

if (!command) {
  process.stderr.write(
    `git-customs: unknown command "${requested}". Run "git-customs --help" for the command list.\n`
  );
  process.exit(1);
}

runScript(command.name, rest);
