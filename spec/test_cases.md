# Plyn Symphony test cases

| Case | Expected result | Automated coverage |
| --- | --- | --- |
| Valid app installation | GitHub issue reads and `github_api` calls use an installation token from the configured command. | `github_adapter_test.exs`: token command |
| Expired token | A later GitHub request obtains a refreshed token without restarting Symphony. | `github_adapter_test.exs`: token command re-evaluation; `test_github_app_auth.py`: cache expiry |
| Missing or failed app credential | GitHub work fails explicitly and never uses a personal token from the environment. | `github_adapter_test.exs`: failed token command; `test_github_app_auth.py`: failure |
| Git repository push authentication | The helper answers only for the configured HTTPS GitHub repository and returns an app token. | `test_github_app_auth.py`: credential request scope |
| Commit creation | The issue workspace's Git author and committer identify the app bot rather than the Mac owner. | `test_github_app_git.py`: workspace Git configuration; manual GitHub attribution check |
