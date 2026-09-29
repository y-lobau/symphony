# Plyn Symphony GitHub identity

Symphony acts as the `kolas-code` GitHub App installation when polling and
updating `kolas-code/plyn` issues and pull requests. It obtains a fresh
installation token when needed, including after an earlier token expires.
GitHub authentication failures stop the affected operation and never fall back
to the Mac owner's GitHub credentials.
The service does not inherit the owner's GitHub CLI login or token variables.

The issue workspace clones and pushes `kolas-code/plyn` over HTTPS with the
same app installation. The Git credential helper supplies the token only for
the configured repository. Commits created in the issue workspace use the
app bot's Git name and email, independently of the Mac owner's global Git
configuration. The sibling `plyn-wiki` checkout remains read-only context.
The unattended worker can create Git branches and commits in its isolated
checkout, so a completed change can reach a pull request without a separate
operator process.

The app's private key and installation configuration stay outside Git and
are readable only by the local user running Symphony. Short-lived tokens are
cached locally with owner-only permissions and refreshed before expiry.

The existing `ready-for-agent` and `symphony-pilot` labels remain the dispatch
gate. The pilot still leaves pull requests open for human review and does not
merge them.
