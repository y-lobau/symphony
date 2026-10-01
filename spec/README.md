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

An open issue is eligible for dispatch when it has the `ready-for-agent` label
and its **Plyn Release** Project Status is **Ready** or **Backlog**. The label
remains on the issue as a standing opt-in. Project Status controls when another
run may start. Pull requests remain open for human review and are not merged
by the worker.

For issues in the **Plyn Release** GitHub Project, Symphony assigns the issue to
`y-lobau` and sets its Project Status to **In progress** when a run starts. If
Codex requests human input, Symphony ends that run, sets the Project Status to
**Human in the Loop**, and blocks the issue. After the human replies in an
issue comment and moves the Project Status to **Ready** or **Backlog**,
Symphony starts a fresh run and sets the Project Status to **In progress**.
The agent is instructed to read the issue's latest comments before continuing.
When the agent opens a pull request, it moves the issue to **In review**.

Project updates use the GitHub App's organization Projects permission. A failed
Project Status read prevents dispatch until the status can be confirmed.
Failures to update the Project or assignee are logged.
