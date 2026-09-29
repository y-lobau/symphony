---
tracker:
  kind: github
  provider:
    repo: kolas-code/plyn
    token: $GITHUB_TOKEN
  required_labels:
    - ready-for-agent
    - symphony-pilot
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 30000
workspace:
  root: /Volumes/ext/git/plyn-symphony/var/workspaces
hooks:
  after_create: |
    git clone git@github.com:kolas-code/plyn.git .
    if [ ! -d ../plyn-wiki/.git ]; then
      git clone git@github.com:kolas-code/plyn-wiki.git ../plyn-wiki
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 8
codex:
  command: /Applications/ChatGPT.app/Contents/Resources/codex app-server
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

Work on GitHub issue {{ issue.identifier }} in `kolas-code/plyn`.

Title: {{ issue.title }}
URL: {{ issue.url }}
Labels: {{ issue.labels }}

Description:
{{ issue.description }}

Use only the isolated repository checkout supplied as your working directory. Read its `AGENTS.md`, `../plyn-wiki/hot.md`, and `../plyn-wiki/index.md` before changing Plyn code. The wiki is provided as a separate sibling checkout for read-only context.

Follow the issue's acceptance criteria and the repository's spec, test case, test, and `make test` rules. Keep the change focused on the issue. Do not handle billing, signing, provisioning, App Store upload, production credentials, or other high-risk work without human approval.

When the work is ready, push a branch over SSH and open a pull request linked to the issue. Use Symphony's `github_api` tool for GitHub API actions such as creating the PR, commenting on the issue, and removing its label; do not depend on `gh` CLI authentication in this unattended session. Include what changed, checks run, manual acceptance steps, and any limitations. Leave the pull request open for human review; do not approve or merge it. Record the PR link in the issue and remove `symphony-pilot` from the issue as the final tracker action so the open issue is not dispatched again. If blocked, explain the blocker on the issue and remove `symphony-pilot` as the final tracker action.
