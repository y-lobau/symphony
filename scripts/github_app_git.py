#!/usr/bin/python3
"""Keep Plyn issue workspaces on the GitHub App identity."""

import json
import os
import subprocess
import sys
from pathlib import Path


CONFIG = Path.home() / "Library/Application Support/plyn-symphony/github-app.json"
AUTH_SCRIPT = Path(__file__).with_name("github_app_auth.py")
GIT = "/usr/bin/git"


def git(args, workspace):
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_ASKPASS"] = "/usr/bin/false"
    subprocess.run([GIT, *args], cwd=workspace, env=environment, check=True)


def credential_helper():
    return f"!/usr/bin/python3 {AUTH_SCRIPT} credential"


def clone_workspace(workspace, config):
    git(
        [
            "-c", "credential.helper=",
            "-c", f"credential.helper={credential_helper()}",
            "-c", "credential.useHttpPath=true",
            "clone", f"https://github.com/{config['repository']}.git", ".",
        ],
        workspace,
    )
    configure_workspace(workspace, config)


def configure_workspace(workspace, config):
    repository = config["repository"]
    bot_login = config["bot_login"]
    bot_id = int(config["bot_id"])
    git(["remote", "set-url", "origin", f"https://github.com/{repository}.git"], workspace)
    git(["config", "--local", "--replace-all", "credential.helper", ""], workspace)
    git(["config", "--local", "--add", "credential.helper", credential_helper()], workspace)
    git(["config", "--local", "credential.useHttpPath", "true"], workspace)
    git(["config", "--local", "user.name", bot_login], workspace)
    git(["config", "--local", "user.email", f"{bot_id}+{bot_login}@users.noreply.github.com"], workspace)


def main():
    config_path = Path(os.environ.get("PLYNSYMPHONY_GITHUB_APP_CONFIG", CONFIG))
    config = json.loads(config_path.read_text())
    workspace = Path.cwd()
    action = sys.argv[1]
    if action == "clone":
        clone_workspace(workspace, config)
    elif action == "configure":
        configure_workspace(workspace, config)
    else:
        raise RuntimeError("Unknown GitHub App Git action")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"GitHub App Git setup failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
