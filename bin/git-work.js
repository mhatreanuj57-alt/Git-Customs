#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { runScript } = require('../lib/run-command');

const command = path.basename(__filename, '.js').replace(/^git-/, '');
runScript(command, process.argv.slice(2));
