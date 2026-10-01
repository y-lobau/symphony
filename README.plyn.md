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
when it has the `ready-for-agent` label and its **Plyn Release** Project Status
is **Ready** or **Backlog**. The label remains on the issue. The workflow
currently runs up to three issues at a time, opens PRs, and leaves review and
merge to humans. Its concurrency is controlled by
`agent.max_concurrent_agents`; increasing that value allows independent issues
to run in parallel.

For issues in the **Plyn Release** GitHub Project, Symphony assigns the issue
to `y-lobau` and sets its Project Status to **In progress** when a run starts.
If Codex requests human input, the run blocks and the status becomes **Human in
the Loop**. The human can reply in an issue comment and move the Project Status
to **Ready** or **Backlog**; Symphony then starts a fresh run and moves the
status to **In progress**. After a pull request is opened, the agent moves the
issue to **In review**. The GitHub App needs organization Projects read/write
permission for these Project Status updates.

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
the Mac owner's GitHub account. Apply `ready-for-agent` only after an issue's
scope and acceptance criteria have been reviewed.
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

The dashboard is at `http://127.0.0.1:4097` on this Mac. From another machine
on the local network, use `http://192.168.0.146:4097` (replace the address if
this Mac's LAN IP changes). The workflow binds the dashboard to all local
network interfaces. Issue history is at `/history` on the same host and port;
it begins with runs started after this feature is deployed and is retained in
`var/logs/history/history.dets`. The issue list pages older work, and each
issue page includes totals, PR links, run context, and an observed event timeline.
To stop the service, run
`launchctl bootout gui/$(id -u)/ai.openclaw.symphony.plyn`; to load it again,
run `launchctl bootstrap gui/$(id -u)
~/Library/LaunchAgents/ai.openclaw.symphony.plyn.plist`. If either installed
file changes, copy its versioned source to the installed path and reload the
LaunchAgent. Keep the plist, wrapper, and stderr path on the internal disk;
launchd cannot reliably open them directly on this volume. The service
retries automatically after the external drive is mounted. Verify a restart
with the state endpoint and check that `blocked` and `retrying` are empty.

The older Python/Fibery service at `/Volumes/ext/git/symphony` is separate.
