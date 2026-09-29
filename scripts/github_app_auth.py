#!/usr/bin/python3
"""Issue short-lived GitHub App tokens for Symphony and its Git client."""

import base64
import datetime
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_CONFIG = Path.home() / "Library/Application Support/plyn-symphony/github-app.json"
REFRESH_MARGIN_SECONDS = 300


def load_config():
    path = Path(os.environ.get("PLYNSYMPHONY_GITHUB_APP_CONFIG", DEFAULT_CONFIG))
    config = json.loads(path.read_text())
    required = {"app_id", "installation_id", "private_key_path", "token_cache_path", "repository"}
    if not required.issubset(config):
        raise RuntimeError("GitHub App configuration is incomplete")
    key_path = Path(config["private_key_path"])
    if key_path.stat().st_mode & 0o077:
        raise RuntimeError("GitHub App private key is accessible by other users")
    return config


def _base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def mint_token(config, now):
    header = _base64url(b'{"alg":"RS256","typ":"JWT"}')
    payload = _base64url(json.dumps({"iat": int(now) - 60, "exp": int(now) + 540, "iss": config["app_id"]}, separators=(",", ":")).encode())
    message = f"{header}.{payload}".encode()
    signature = subprocess.run(
        ["/usr/bin/openssl", "dgst", "-sha256", "-sign", config["private_key_path"]],
        input=message,
        capture_output=True,
        check=True,
    ).stdout
    jwt = f"{header}.{payload}.{_base64url(signature)}"
    request = urllib.request.Request(
        f"https://api.github.com/app/installations/{config['installation_id']}/access_tokens",
        data=b"{}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {jwt}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "plyn-symphony",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"GitHub App token request returned HTTP {error.code}") from None
    expiry = datetime.datetime.fromisoformat(data["expires_at"].replace("Z", "+00:00")).timestamp()
    return data["token"], expiry


def get_token(config, now=None):
    now = time.time() if now is None else now
    cache_path = Path(config["token_cache_path"])
    cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = cache_path.with_suffix(cache_path.suffix + ".lock")
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            cached = json.loads(cache_path.read_text())
            if cached["expires_at"] > now + REFRESH_MARGIN_SECONDS and cached["token"]:
                return cached["token"]
        except (FileNotFoundError, KeyError, ValueError, TypeError):
            pass

        token, expiry = mint_token(config, now)
        with tempfile.NamedTemporaryFile("w", dir=cache_path.parent, prefix=".github-app-token-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            os.chmod(temporary_path, 0o600)
            json.dump({"token": token, "expires_at": expiry}, temporary)
        os.replace(temporary_path, cache_path)
        return token


def matches_git_request(config, raw_request):
    fields = dict(line.split("=", 1) for line in raw_request.splitlines() if "=" in line)
    repository_path = config["repository"]
    path = fields.get("path", "").removesuffix(".git").rstrip("/")
    return fields.get("protocol") == "https" and fields.get("host") == "github.com" and path == repository_path


def main():
    config = load_config()
    action = sys.argv[1] if len(sys.argv) > 1 else "token"
    if action == "token":
        print(get_token(config))
    elif action == "credential":
        operation = sys.argv[2] if len(sys.argv) > 2 else "get"
        if operation == "get" and matches_git_request(config, sys.stdin.read()):
            print("username=x-access-token")
            print(f"password={get_token(config)}")
            print()
    else:
        raise RuntimeError("Unknown GitHub App authentication action")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"GitHub App authentication failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
