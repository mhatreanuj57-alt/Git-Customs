# anuj-custom-git-command-list

A collection of tested Git extension commands for Windows. The package adds nine
`git <command>` commands for GitHub Actions, pull requests, releases, safe per-file
commits, worktrees, repository diagnostics, and security checks.

The commands run on Windows PowerShell 5.1 or later and are installed through npm as
Git external commands. GitHub-aware commands use the GitHub CLI (`gh`).

## Commands

| Command | Purpose |
| --- | --- |
| `git action-workflow` | Create, validate, inspect, watch, retry, and read logs for GitHub Actions workflows. |
| `git action-fix` | Diagnose a failed Actions run, propose a narrow fix, and require approval before editing, pushing, or retrying. |
| `git suggest` | Preview per-file `git add`, `git commit`, and `git push` commands without executing them. |
| `git autopush` | Execute the same per-file plan, pushing one commit per changed file and stopping on the first failure. |
| `git work` | List, create, and safely remove linked Git worktrees. |
| `git doctor` | Run read-only repository and GitHub diagnostics. |
| `git security-check` | Scan for credentials and common GitHub Actions security problems. |
| `git pr-flow` | Inspect pull requests and checks, or create a pull request without pushing. |
| `git release` | Inspect release state, create an annotated local tag, or publish a GitHub release. |

The package also provides `git-customs` and `anuj-custom-git-command-list` as a
command index and dispatcher:

```powershell
git-customs --help
git-customs list
git-customs run doctor --no-github
```

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 or PowerShell 7+.
- Git for Windows.
- Node.js 18 or newer and npm (needed to install the package).
- GitHub CLI (`gh`) for commands that contact GitHub.
- A `gh` login with `repo` and `workflow` access for remote GitHub operations:

```powershell
gh auth login
gh auth status
```

Local commands such as `init`, `work`, `doctor --no-github`, `security-check`, and
`release tag` do not require GitHub CLI authentication. Commands that read or change
GitHub state do.

## Installation

Install the published package globally:

```powershell
npm install -g anuj-custom-git-command-list
```

To install from a local checkout instead:

```powershell
cd C:\path\to\Git-Customs
npm install -g .
```

Open a new terminal after installation so npm's global binary directory is visible.
Then verify the commands:

```powershell
git action-workflow -h
git action-fix -h
git suggest -h
git autopush -h
git work -h
git doctor -h
git security-check -h
git pr-flow -h
git release -h
```

The npm package installs extensionless shims alongside `.cmd` and `.ps1` wrappers, so
Git for Windows can discover the commands as `git <command>`. The underlying command
implementations are PowerShell scripts bundled with the package.

### Updating

```powershell
npm update -g anuj-custom-git-command-list
```

### Uninstallation

```powershell
npm uninstall -g anuj-custom-git-command-list
```

Then verify the shims are gone:

```powershell
where.exe git-action-workflow
where.exe git-customs
```

If you previously installed the commands manually under `%USERPROFILE%\.git-action-workflow`
or `%USERPROFILE%\.git-suggest`, remove those directories from your user `PATH` as
well. The npm package does not modify those directories.

## Usage conventions

- Run commands from inside a Git repository unless the command explicitly only needs
  its own arguments.
- Use `git <command> -h` or `git <command> <subcommand> -h` for help. Git intercepts
  `--help` for external commands on some installations, so `-h` is more reliable.
- Interactive confirmations are used for destructive or remote write operations.
  Non-interactive automation should pass `--yes` only where a command documents it.
- Commands return a non-zero exit code on failure. CI-friendly read-only commands use
  exit codes to indicate whether checks passed or warnings were treated as errors.
- GitHub-aware commands verify repository, branch, run, tag, and workflow identity
  before performing remote actions.

## git action-workflow

Manages GitHub Actions workflows for the current repository.

```powershell
git action-workflow init
git action-workflow validate
git action-workflow status
git action-workflow watch
git action-workflow logs --failed
git action-workflow retry --yes
```

Subcommands:

- `init`: creates `.github/workflows/action-workflow.yml` or a named workflow without
  overwriting an existing file. Use `--name`, `--file`, or `--dry-run`. It does not
  stage, commit, or push.
- `validate`: checks local workflow structure and, optionally, GitHub registration.
  Use `--workflow <selector>` and `--require-remote`.
- `status`: shows recent runs. Use `--workflow`, `--branch`, `--all-branches`, and
  `--limit`.
- `watch`: polls a verified run until it finishes. Use `--run`, `--workflow`,
  `--branch`, `--all-branches`, `--interval`, and `--timeout`.
- `logs`: prints verified run or job logs. Use `--run`, `--workflow`, `--branch`,
  `--all-branches`, `--failed`, and `--job`.
- `retry`: re-runs a completed unsuccessful run after confirmation. Use `--run`,
  `--workflow`, `--branch`, `--all-branches`, `--all`, and `--yes`.

Workflow selectors accept a display name, a repository-relative path, a filename, or
a workflow id. Ambiguous selectors fail instead of choosing arbitrarily.

## git action-fix

Diagnoses a failed GitHub Actions run, proposes one narrow remediation, and requires
approval before editing. With no options it selects the latest failed run on the
current branch.

```powershell
git action-fix
git action-fix --run 123456789 --dry-run
git action-fix --workflow ci.yml
git action-fix --branch main --interval 5 --timeout 300
```

Supported automatic fixes are intentionally limited to proven cases such as a
missing trusted Python package, a Node.js major version requirement, or an `npm ci`
command without a lockfile. Authentication failures, missing secrets, leaked
credentials, and unrecognized failures are never edited or retried automatically.

Safety checks include:

- the current branch must match the failed run branch;
- `HEAD` must be the exact failed commit;
- the worktree and upstream branch must be synchronized and clean;
- only tracked, regular, non-sensitive files can be edited;
- a second approval is required before committing and pushing;
- failed validation or commit operations roll back the edit;
- the recovery run must be verified before success is reported.

There is no `--yes` or approval bypass for `action-fix`.

## git suggest

Previews diff-based Conventional Commit messages and the corresponding Git commands.
Nothing is executed. By default it suggests one commit per changed file; `--combined`
suggests one commit for all pending paths.

```powershell
git suggest
git suggest --combined
```

The output is a reviewable plan. Commands use literal path arguments, so spaces,
quotes, dollar signs, leading dashes, brackets, and Git-glob characters are treated as
filename characters rather than shell or pathspec syntax. Staged, modified, deleted,
renamed, copied, and untracked files are detected. Unresolved conflicts are rejected.

Requirements: a Git worktree with an `origin` remote and an attached branch.

## git autopush

Re-detects the pending changes, shows the diff-based commit messages, and asks for
confirmation before staging, committing, and pushing. By default it creates one
commit per file and pushes each successful commit. `--combined` creates one commit
and one push for all pending paths.

```powershell
git autopush
git autopush --combined
```

Messages use Conventional Commit types and changed content where it can be inferred;
binary changes get add, update, or remove asset messages. Unclear text changes use a
file-scoped fallback without a commit counter. The diff content is not printed.

`autopush` re-checks the repository before every file in the default mode. If the
branch, origin URL, or pending plan changes, it stops. A failed add, commit, or push
stops the run immediately. Completed files remain committed and pushed; remaining
files stay pending. There is no rollback.

Use `git suggest` first when you want to inspect the exact plan, or when you do not
want any commits created.

## git work

Creates and manages isolated linked worktrees.

```powershell
git work list
git work add feature/login
git work add feature/login --base origin/main --path "$HOME\src\login"
git work remove feature/login
git work remove feature/login --force --yes
git work prune
git work prune --apply
```

- `list`: shows worktrees and marks the current one.
- `add <branch> [--base <ref>] [--path <dir>]`: creates the branch from `--base`
  (default `HEAD`) when needed, or checks out an existing branch. The default path is
  `<repo-parent>/<repo>-worktrees/<branch>`.
- `remove <path-or-branch> [--force] [--yes]`: removes a linked worktree after
  confirmation. The branch is kept. The main worktree and the current worktree are
  refused. `--force` permanently discards a dirty worktree's changes.
- `prune [--apply] [--dry-run] [--yes]`: previews stale metadata by default. `--apply`
  removes only stale metadata after confirmation.

## git doctor

Runs read-only diagnostics for repository discovery, branch and worktree state,
GitHub Actions workflow files, and optionally GitHub CLI authentication and repository
access.

```powershell
git doctor
git doctor --no-github
git doctor --strict
```

`--no-github` skips remote checks. `--strict` exits non-zero when warnings are found.
The command never changes files, refs, or remotes.

## git security-check

Scans tracked files, untracked non-ignored files, and workflow files for credential
patterns, risky credential files, and common GitHub Actions security issues.

```powershell
git security-check
git security-check --staged
git security-check --secrets-only
git security-check --workflows-only --strict
```

- `--staged`: scan staged content instead of the working tree.
- `--secrets-only`: skip workflow checks.
- `--workflows-only`: skip credential scanning.
- `--strict`: exit non-zero when warnings are found.

`--secrets-only` and `--workflows-only` cannot be combined. Findings are redacted.
Exit codes are `0` for clean or warnings, and `1` for errors or warnings with
`--strict`.

## git pr-flow

Inspects pull requests and CI checks, or creates a pull request after confirmation.
`create` never pushes.

```powershell
git pr-flow status
git pr-flow status --number 42
git pr-flow status --branch feature/login
git pr-flow create --title "Add login" --body "Adds the login flow."
git pr-flow create --title "Add login" --body-file .\pr-body.md --base main --draft
git pr-flow checks --watch --interval 5 --timeout 120
```

- `status [--number <id>] [--branch <name>]`: read-only pull request summary.
- `create --title <title> [--body <text>] [--body-file <path>] [--base <branch>] [--draft] [--yes]`:
  creates a PR for the current branch. The branch must already be pushed and exactly
  match `origin/<branch>`.
- `checks [--number <id>] [--branch <name>] [--watch] [--interval <seconds>] [--timeout <seconds>]`:
  read-only checks. `--watch` polls until completion or timeout.

`--body` and `--body-file` cannot be combined. A title must be 1-256 characters.
`checks` exits `0` for passing or no checks and `1` for pending, failing, or timed-out
checks.

## git release

Inspects release state, creates a local annotated tag, or publishes a GitHub release.

```powershell
git release status
git release tag 1.2.3
git release tag v1.2.3 --yes
git release publish 1.2.3
git release publish v1.2.3 --title "Version 1.2.3" --notes "Release notes"
git release publish 1.2.3 --notes-file .\notes.md --draft --prerelease
```

- `status`: shows the latest tag, suggested next version, branch synchronization, and
  whether the latest tag has a GitHub release.
- `tag <version> [--yes]`: creates an annotated tag at `HEAD`. Local only.
- `publish <version> [--title <title>] [--notes <text>] [--notes-file <path>] [--draft] [--prerelease] [--yes]`:
  pushes the tag and creates a GitHub release after confirmation.

Versions use semantic versioning such as `1.2.3` or `1.2.3-beta.1`; a leading `v` is
accepted. `publish` requires an existing local tag at `HEAD`, a clean worktree, the
default branch, and an exact match with `origin/<default-branch>`. It refuses if the
remote tag points elsewhere or the release already exists. `--notes` and
`--notes-file` cannot be combined.

The tag is pushed before the release is created. If release creation fails, the
pushed tag remains and is reported.

## Common workflow

```powershell
git action-workflow init
git add .github/workflows/action-workflow.yml
git commit -m "Add GitHub Actions workflow"
git push

git action-workflow validate
git action-workflow status
git action-workflow watch
```

If a run fails:

```powershell
git action-workflow status
git action-workflow logs --failed
git action-fix --dry-run
git action-fix
```

For a quick local repository check before committing:

```powershell
git doctor --no-github
git security-check
git suggest
```

## Safety and behavior

- `git action-workflow init` uses create-new semantics and never overwrites files.
- Workflow, run, job, PR, tag, and branch selectors are verified before remote actions.
- `git action-fix` has no approval bypass and never edits sensitive files.
- `git work remove` keeps the branch and refuses the main/current worktree.
- `git work prune` previews by default and deletes only stale metadata.
- `git doctor` and `git security-check` are read-only.
- `git security-check` redacts findings and skips ignored files.
- `git pr-flow create` never pushes.
- `git release publish` and `git action-workflow retry` require confirmation unless
  `--yes` is supplied.
- The commands do not force-push or rewrite Git history.

## Development and testing

The package has no runtime npm dependencies. The command implementations are bundled
PowerShell scripts; the Node entry points launch them with inherited stdio and forward
their exit codes.

```powershell
npm test
```

The test command runs all PowerShell command suites, the Node CLI entry-point tests,
and an install test that packs the npm tarball, installs it into a temporary prefix,
and exercises every installed Git command. To run only the command suites:

```powershell
npm run test:commands
```

To inspect the published file list without installing:

```powershell
npm run pack:check
```

## Troubleshooting

### `git <command>` is not found

Open a new terminal after installation. Check that npm's global binary directory is on
`PATH`:

```powershell
npm config get prefix
where.exe git-doctor
```

If the shim exists but Git cannot find it, confirm that Git for Windows is installed
and that `where.exe git-doctor` resolves to npm's global directory. Reinstalling with
`npm install -g anuj-custom-git-command-list --force` recreates the shims.

### PowerShell cannot run the command

The Node wrapper launches PowerShell with a process-only execution-policy bypass and
does not change the machine policy. If PowerShell is installed in a non-standard
location, set:

```powershell
$env:GIT_CUSTOMS_POWERSHELL = 'C:\path\to\powershell.exe'
```

### GitHub CLI is missing or not authenticated

```powershell
gh --version
gh auth status
gh auth login
```

Remote commands require a login with `repo` and `workflow` access.

### A workflow run or pull request cannot be found

Check the repository remote and current branch:

```powershell
git remote -v
git status
gh run list
```

Pass `--branch` or `--all-branches` where the command supports them. Run and job ids
are verified against the repository before remote requests.

### The current branch is detached

Check out a branch or pass an explicit `--branch` where supported. Commands that need
an attached branch fail rather than guessing.

### A command refuses an operation

Read the error and rerun with `-h`. Destructive operations require confirmation and
may require `--yes` only in non-interactive contexts. `action-fix` cannot bypass
approval, and release publishing requires a clean, synchronized default branch.

## License

MIT. See [LICENSE](LICENSE).
