# Plyn Symphony pilot

The GitHub identity behavior and test cases are specified in `spec/README.md`
and `spec/test_cases.md`.

This checkout is based on the official OpenAI Symphony Elixir implementation
at `v0.0.3`, with a local GitHub App token-command extension. The service runs
the locally built `elixir/bin/symphony` escript. Runtime logs and isolated
issue workspaces are stored in ignored `var/` on the external drive.

To build the local runtime, install Erlang/OTP 28 and Elixir 1.19.5 for OTP 28,
then run:

```sh
cd /Volumes/ext/git/plyn-symphony/elixir
mix deps.get
make test
mix escript.build
```

`WORKFLOW.plyn.md` polls open issues in `kolas-code/plyn`. An issue is eligible
only when it has both `ready-for-agent` and `symphony-pilot` labels. The latter
is an explicit pilot gate. The workflow
runs one issue at a time, opens a PR, and leaves review and merge to humans.

Start in the foreground:

```sh
cd /Volumes/ext/git/plyn-symphony
./scripts/run-plyn-symphony.sh
```

The launcher obtains short-lived credentials from the `kolas-code` GitHub App,
whose private key and installation configuration are kept outside Git under
`~/Library/Application Support/plyn-symphony/`. The app is installed only on
`kolas-code/plyn` and has repository Contents, Issues, and Pull requests write
permissions. Git pushes use the app over HTTPS, and issue-workspace commits
use the app bot's name and email. Authentication failures do not fall back to
the Mac owner's GitHub account. Do not apply `symphony-pilot` to an issue until
its scope and acceptance criteria have been reviewed for this pilot.
Codex turns use `danger-full-access` because Codex protects `.git` metadata
from writes in `workspace-write` mode, which prevents unattended commits.
The workflow prompt instructs the agent to work in its isolated checkout; the GitHub
App installation limits GitHub write access to `kolas-code/plyn`.

The unattended service is a user LaunchAgent named
`ai.openclaw.symphony.plyn`. Its installed plist is at
`~/Library/LaunchAgents/ai.openclaw.symphony.plyn.plist`, with a versioned copy
in `launchd/`. The small wrapper is installed at
`~/Library/Application Support/plyn-symphony/run.sh`, with its source in
`scripts/run-plyn-symphony-launchd.sh`. launchd must open that wrapper and its
stderr file on the internal disk. The wrapper starts the locally built
escript, workflow, issue workspaces, and Symphony logs on `/Volumes/ext`.
No token is saved in the plist or repository. ChatGPT has Full Disk Access in macOS System Settings;
the `escript` executable has Removable Volumes access in Files & Folders. These
permissions let the process use this external volume unattended. The GitHub
CLI config directory is isolated under the internal app-support directory.

Control and inspect the service:

```sh
launchctl print gui/$(id -u)/ai.openclaw.symphony.plyn
launchctl kickstart -k gui/$(id -u)/ai.openclaw.symphony.plyn
curl -fsS http://127.0.0.1:4097/api/v1/state
```

The dashboard is at `http://127.0.0.1:4097`. To stop the service, run
`launchctl bootout gui/$(id -u)/ai.openclaw.symphony.plyn`; to load it again,
run `launchctl bootstrap gui/$(id -u)
~/Library/LaunchAgents/ai.openclaw.symphony.plyn.plist`. If either installed
file changes, copy its versioned source to the installed path and reload the
LaunchAgent. Keep the plist, wrapper, and stderr path on the internal disk;
launchd cannot reliably open them directly on this volume. The service
retries automatically after the external drive is mounted. Verify a restart
with the state endpoint and check that `blocked` and `retrying` are empty.

The older Python/Fibery service at `/Volumes/ext/git/symphony` is separate.
