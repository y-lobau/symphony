# Plyn Symphony pilot

This checkout pins the official OpenAI Symphony Elixir implementation at `v0.0.3`.
The verified macOS ARM release is stored in ignored `bin/`. Runtime logs and
isolated issue workspaces are stored in ignored `var/` on the external drive.

To restore the pinned binary in another checkout:

```sh
mkdir -p bin
gh release download v0.0.3 --repo openai/symphony \
  --pattern 'symphony-v0.0.3-macos_arm64*' --dir bin
(cd bin && shasum -a 256 -c symphony-v0.0.3-macos_arm64.sha256)
chmod 755 bin/symphony-v0.0.3-macos_arm64
```

`WORKFLOW.plyn.md` polls open issues in `kolas-code/plyn`. An issue is eligible
only when it has both `ready-for-agent` and `symphony-pilot` labels. The latter
is an explicit pilot gate, and no issue currently carries it. The workflow
runs one issue at a time, opens a PR, and leaves review and merge to humans.

Start in the foreground:

```sh
cd /Volumes/ext/git/plyn-symphony
./scripts/run-plyn-symphony.sh
```

The launcher reads GitHub credentials from the local `gh` login at runtime and
does not store a token in this checkout. It includes the acknowledgement flag
required by Symphony's preview CLI. Do not apply `symphony-pilot` to an issue
until its scope and acceptance criteria have been reviewed for this pilot.

The unattended service is a user LaunchAgent named
`ai.openclaw.symphony.plyn`. Its installed plist is at
`~/Library/LaunchAgents/ai.openclaw.symphony.plyn.plist`, with a versioned copy
in `launchd/`. The small wrapper is installed at
`~/Library/Application Support/plyn-symphony/run.sh`, with its source in
`scripts/run-plyn-symphony-launchd.sh`. launchd must open that wrapper and its
stderr file on the internal disk. The wrapper starts the verified binary,
workflow, issue workspaces, and Symphony logs directly on `/Volumes/ext` and
reads the existing GitHub CLI credential at startup. No token is saved in the
plist or repository. ChatGPT has Full Disk Access in macOS System Settings;
this was needed for the process to use this external volume unattended.

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
retries automatically after the external drive is mounted. A restart and a
`200` response from the state endpoint were verified with no eligible issues.

The older Python/Fibery service at `/Volumes/ext/git/symphony` is separate.
