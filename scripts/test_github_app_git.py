import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("github_app_git.py")
spec = importlib.util.spec_from_file_location("github_app_git", SCRIPT)
git_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(git_app)


class GitHubAppGitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.workspace = Path(self.tmp.name)
        subprocess.run(["/usr/bin/git", "init", "-q", str(self.workspace)], check=True)
        subprocess.run(["/usr/bin/git", "remote", "add", "origin", "git@github.com:kolas-code/plyn.git"], cwd=self.workspace, check=True)
        self.config = {"repository": "kolas-code/plyn", "bot_login": "plyn-symphony-agent[bot]", "bot_id": 12345}

    def git_config(self, key):
        return subprocess.check_output(["/usr/bin/git", "config", "--local", "--get", key], cwd=self.workspace, text=True).strip()

    def test_configures_https_app_auth_and_bot_commit_identity(self):
        git_app.configure_workspace(self.workspace, self.config)

        self.assertEqual(self.git_config("remote.origin.url"), "https://github.com/kolas-code/plyn.git")
        self.assertEqual(self.git_config("user.name"), "plyn-symphony-agent[bot]")
        self.assertEqual(self.git_config("user.email"), "12345+plyn-symphony-agent[bot]@users.noreply.github.com")
        self.assertEqual(self.git_config("credential.useHttpPath"), "true")
        helpers = subprocess.check_output(["/usr/bin/git", "config", "--local", "--get-all", "credential.helper"], cwd=self.workspace, text=True).splitlines()
        self.assertEqual(helpers[0], "")
        self.assertIn("github_app_auth.py credential", helpers[1])


if __name__ == "__main__":
    unittest.main()
