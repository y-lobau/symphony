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

The pilot is run in the foreground for now. This Mac's LaunchAgent could not
read the external-drive script and then stalled on headless GitHub credential
access, so no background service is installed. The foreground run was verified
through the dashboard API at `http://127.0.0.1:4097/api/v1/state` when started
with `./scripts/run-plyn-symphony.sh --port 4097`.

The older Python/Fibery service at `/Volumes/ext/git/symphony` is separate.
