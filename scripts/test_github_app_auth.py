import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("github_app_auth.py")
spec = importlib.util.spec_from_file_location("github_app_auth", SCRIPT)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class GitHubAppAuthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = {
            "app_id": 123,
            "installation_id": 456,
            "private_key_path": str(Path(self.tmp.name) / "key.pem"),
            "token_cache_path": str(Path(self.tmp.name) / "token.json"),
            "repository": "kolas-code/plyn",
        }

    def test_reuses_and_refreshes_installation_token_before_expiry(self):
        with patch.object(auth, "mint_token", side_effect=[("app-one", 3600), ("app-two", 7200)]) as mint:
            self.assertEqual(auth.get_token(self.config, now=100), "app-one")
            self.assertEqual(auth.get_token(self.config, now=200), "app-one")
            self.assertEqual(auth.get_token(self.config, now=3400), "app-two")
            self.assertEqual(mint.call_count, 2)

        self.assertEqual(Path(self.config["token_cache_path"]).stat().st_mode & 0o777, 0o600)

    def test_failed_refresh_does_not_fall_back_to_expired_or_personal_token(self):
        with patch.object(auth, "mint_token", side_effect=[("app-one", 3600), RuntimeError("unavailable")]):
            self.assertEqual(auth.get_token(self.config, now=100), "app-one")
            with self.assertRaises(RuntimeError):
                auth.get_token(self.config, now=3400)

    def test_git_credential_is_scoped_to_configured_https_repository(self):
        request = "protocol=https\nhost=github.com\npath=kolas-code/plyn.git\n\n"
        self.assertTrue(auth.matches_git_request(self.config, request))
        self.assertFalse(auth.matches_git_request(self.config, request.replace("plyn.git", "other.git")))
        self.assertFalse(auth.matches_git_request(self.config, request.replace("https", "http")))
        self.assertFalse(auth.matches_git_request(self.config, request.replace("github.com", "example.com")))


if __name__ == "__main__":
    unittest.main()
