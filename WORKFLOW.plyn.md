---
tracker:
  kind: github
  provider:
    repo: kolas-code/plyn
    token_command: /Volumes/ext/git/plyn-symphony/scripts/github_app_auth.py
    project: Plyn Release
    agent_assignee: y-lobau
    comment_policy: handoff_only
    dispatch_statuses:
      - Ready
      - Backlog
  required_labels:
    - ready-for-agent
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 30000
server:
  host: 0.0.0.0
  port: 4097
workspace:
  root: /Volumes/ext/git/plyn-symphony/var/workspaces
hooks:
  after_create: |
    /usr/bin/python3 /Volumes/ext/git/plyn-symphony/scripts/github_app_git.py clone
    if [ ! -d ../plyn-wiki/.git ]; then
      git clone git@github.com:kolas-code/plyn-wiki.git ../plyn-wiki
    fi
  before_run: /usr/bin/python3 /Volumes/ext/git/plyn-symphony/scripts/github_app_git.py configure
agent:
  max_concurrent_agents: 3
  max_turns: 8
codex:
  command: /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

Work on GitHub issue {{ issue.identifier }} in `kolas-code/plyn`.

Title: {{ issue.title }}
URL: {{ issue.url }}
Labels: {{ issue.labels }}

Description:
{{ issue.description }}

Use only the isolated repository checkout supplied as your working directory. Read its `AGENTS.md`, `../plyn-wiki/hot.md`, and `../plyn-wiki/index.md` before changing Plyn code. The wiki is provided as a separate sibling checkout for read-only context. Before starting work, read the issue comments with `github_api` (`GET /repos/kolas-code/plyn/issues/{{ issue.id }}/comments?per_page=100`, paging if needed); they may contain the human's response to an earlier input request or the existing marked handoff comment.

Follow the issue's acceptance criteria and the repository's spec, test case, test, and `make test` rules. Keep the change focused on the issue. Do not handle billing, signing, provisioning, App Store upload, production credentials, or other high-risk work without human approval.

### Simulator permission preflight

For iOS acceptance work that needs a simulator permission such as keyboard Full Access, first verify the installed app and extension identity, build/configuration, Firebase project, simulator UDID, and current permission state using available read-only checks. Do not ask the human to approve a permission until this preflight is complete; if the Firebase project or build cannot be identified, report that exact blocker and continue independent acceptance work.

Before asking, read the latest issue comments for an explicit human decision from an earlier round. An existing approval applies only to the same simulator UDID, app/extension identity and build configuration, verified Firebase project, and permission scope. If those match and the requested permission is already enabled, continue without asking again. If an exact prior approval is documented and the permission needs to be enabled again for that same setup, treat it as authorization for this QA acceptance flow. Ask again only when there is no applicable approval, the setup or scope changed, or the prior decision was a denial or remains unanswered. Keep approval for simulator QA separate from production credentials, releases, or other permissions.

### Simulator UI acceptance

When a Simulator UI bridge cannot find a web field or custom keyboard control, or reports `windowNotFoundAtPosition`, capture a fresh screenshot, confirm the active Simulator window and its current dimensions, and retry the interaction against that screenshot. Refocus the source field after returning from the companion; screen coordinates from before navigation are stale. If a semantic accessibility snapshot omits the custom keyboard, try the visual CUA path and the repository's focused XCUI test before escalating. For the cold keyboard recovery path in TC-12, run `ONLY_TESTING=PlynKeyboardE2ETests/PlynKeyboardColdRecoveryUITests ./ios/scripts/run_e2e_ios.sh` from `code/plyn-keyboard-app`; it uses a runner-owned Simulator and a synthetic transcript to check recovery, idle return, a fresh microphone press, and document insertion. Report the distinction between that deterministic UI proof and live audio or physical-device validation. Ask the human to operate the Simulator only after the independent automation paths fail with a reproducible blocker.

Treat GitHub issue comments as a human handoff channel, not a progress log. Put test results, attempts, and limitations in the pull request; Symphony history carries run progress. If human input is required, ask one focused question describing the exact action and verified target. First check for an existing unresolved question or applicable approval. If a marked handoff comment already exists, do not post another; edit that comment only if the required human action materially changed. Otherwise post one question with `<!-- symphony:human-handoff -->` at the end of its body. Then yield input-required so Symphony sets Human in the Loop and ends this run. Do not keep posting validation updates or repeat the question while waiting. A later run may resume without a human reply when new automated evidence resolves the exact handoff blocker; edit the marked comment in place to say no human action is needed and put the verification details in the PR.

When the work is ready, push a branch through the configured HTTPS origin and open a pull request linked to the issue. Use Symphony's `github_api` tool for GitHub API actions such as creating the PR and updating Project Status via `POST /graphql`; do not depend on `gh` CLI authentication in this unattended session. Include what changed, checks run, manual acceptance steps, limitations, and an issue-closing reference in the PR. Leave the pull request open for human review; do not approve or merge it. Link the PR to the issue through the PR body, not a new issue comment, and set its Plyn Release Project Status to `In review` as the final tracker action. Keep `ready-for-agent` on the issue. If you need a human answer, use the single handoff comment described above. When Symphony detects the app-server input-required event, it will set Project Status to `Human in the Loop` and end this run. A human answer or a separately verified automated resolution may move Project Status to `Ready` or `Backlog` to trigger a fresh run.
