---
name: 'Intelligent Terminal Security Repair Analysis'
description: 'Same-repository security review worker that may produce one validated HIGH-confidence repair artifact.'

on:
  workflow_dispatch:
    inputs:
      dispatch_id:
        description: 'Controller correlation identifier'
        required: true
        type: string
      pr_number:
        description: 'Pull request number'
        required: true
        type: string
      repo:
        description: 'Target owner/repository'
        required: true
        type: string
      expected_head_sha:
        description: 'Immutable pull request head'
        required: true
        type: string
      expected_base_sha:
        description: 'Observed pull request base tip'
        required: true
        type: string
      comparison_base_sha:
        description: 'Controller-resolved merge base'
        required: true
        type: string
      head_ref:
        description: 'Pull request head branch'
        required: true
        type: string
      head_repo:
        description: 'Pull request head repository'
        required: true
        type: string

permissions:
  contents: read
  pull-requests: read
  actions: read
  checks: read
  security-events: read
  copilot-requests: write

engine: copilot

skills:
  - .github/skills/ghaw-pr-security

checkout:
  ref: ${{ github.event.inputs.expected_head_sha }}
  fetch-depth: 0

tools:
  edit:
  bash:
    - 'git diff:*'
    - 'git grep:*'
    - 'git rev-parse:*'
    - 'git show:*'
    - 'git status:*'
    - 'cargo fmt:*'
    - 'cargo test:*'
    - 'node --test:*'

jobs:
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      trusted_code_revision: ${{ steps.validate.outputs.trusted_code_revision }}
    steps:
      - name: Validate immutable dispatch
        id: validate
        shell: bash
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          EXPECTED_HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          EXPECTED_BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          COMPARISON_BASE_SHA: ${{ github.event.inputs.comparison_base_sha }}
          HEAD_REPO: ${{ github.event.inputs.head_repo }}
          REPOSITORY: ${{ github.repository }}
          TRUSTED_WORKFLOW_SHA: ${{ github.workflow_sha }}
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]
          [[ "$EXPECTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]
          [[ "$EXPECTED_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]
          [[ "$COMPARISON_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]
          [ "$TRUSTED_WORKFLOW_SHA" = "$EXPECTED_BASE_SHA" ]
          [ "$HEAD_REPO" = "$REPOSITORY" ]
          current_head="$(gh api "/repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.sha)"
          current_head_repo="$(gh api "/repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.repo.full_name)"
          [ "$current_head" = "$EXPECTED_HEAD_SHA" ]
          [ "$current_head_repo" = "$HEAD_REPO" ]
          echo "trusted_code_revision=$EXPECTED_HEAD_SHA" >> "$GITHUB_OUTPUT"

  agent:
    needs: [prepare]

safe-outputs:
  staged: true
  report-failure-as-issue: false
  create-check-run:
    max: 1
    staged: true
  missing-data:
    create-issue: false
  missing-tool:
    create-issue: false
  noop:
    report-as-issue: false
  report-incomplete:
    create-issue: false

steps:
  - name: Prepare immutable repair scope
    shell: bash
    env:
      EXPECTED_BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
      EXPECTED_HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
      COMPARISON_BASE_SHA: ${{ github.event.inputs.comparison_base_sha }}
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      TRUSTED_SHA: ${{ github.workflow_sha }}
    run: |
      set -euo pipefail
      rm -f /tmp/gh-aw/security-scope.json /tmp/gh-aw/security-findings.json
      trusted_validator="$RUNNER_TEMP/security-review.mjs"
      git show "$TRUSTED_SHA:.github/skills/ghaw-pr-security/scripts/security-review.mjs" > "$trusted_validator"
      node "$trusted_validator" scope \
        --base "$EXPECTED_BASE_SHA" \
        --head "$EXPECTED_HEAD_SHA" \
        --pr "$PR_NUMBER" \
        --relation same-repo \
        --mode repair \
        --output /tmp/gh-aw/security-scope.json
      [ "$(node -p "JSON.parse(require('fs').readFileSync('/tmp/gh-aw/security-scope.json','utf8')).baseSha")" = "$COMPARISON_BASE_SHA" ]

post-steps:
  - name: Reject stale or malformed repair output
    shell: bash
    env:
      GH_TOKEN: ${{ github.token }}
      EXPECTED_BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
      EXPECTED_HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
      COMPARISON_BASE_SHA: ${{ github.event.inputs.comparison_base_sha }}
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      REPOSITORY: ${{ github.event.inputs.repo }}
      TRUSTED_SHA: ${{ github.workflow_sha }}
    run: |
      set -euo pipefail
      current_head="$(gh api "/repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.sha)"
      [ "$current_head" = "$EXPECTED_HEAD_SHA" ] || {
        echo "::error::Stale security repair rejected: expected $EXPECTED_HEAD_SHA, found $current_head."
        exit 1
      }
      trusted_validator="$RUNNER_TEMP/security-review-final.mjs"
      git show "$TRUSTED_SHA:.github/skills/ghaw-pr-security/scripts/security-review.mjs" > "$trusted_validator"
      source_workspace="$GITHUB_WORKSPACE"
      trusted_workspace="$RUNNER_TEMP/security-repair-workspace"
      trusted_scope="$RUNNER_TEMP/security-scope.final.json"
      trusted_report="$RUNNER_TEMP/security-findings.attested.json"
      rm -rf "$trusted_workspace"
      rm -f "$trusted_scope" "$trusted_report" \
        /tmp/gh-aw/security-findings.validated.json \
        /tmp/gh-aw/security-summary.md \
        /tmp/gh-aw/security-status.txt \
        /tmp/gh-aw/security-repair.patch
      mkdir "$trusted_workspace"
      askpass="$RUNNER_TEMP/security-git-askpass.sh"
      cat > "$askpass" <<'EOF'
      #!/bin/sh
      case "$1" in
        *Username*) printf '%s\n' x-access-token ;;
        *) printf '%s\n' "$GH_TOKEN" ;;
      esac
      EOF
      chmod 700 "$askpass"
      export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0
      export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
      git -C "$trusted_workspace" init --quiet
      git -C "$trusted_workspace" remote add origin "$GITHUB_SERVER_URL/$REPOSITORY.git"
      git -C "$trusted_workspace" fetch --quiet --no-tags --filter=blob:none origin \
        "$EXPECTED_BASE_SHA" "$EXPECTED_HEAD_SHA"
      git -C "$trusted_workspace" checkout --quiet --detach "$EXPECTED_HEAD_SHA"
      git -C "$trusted_workspace" remote remove origin
      rm -f "$askpass"
      unset GIT_ASKPASS GH_TOKEN
      pushd "$trusted_workspace"
      node "$trusted_validator" scope \
        --base "$EXPECTED_BASE_SHA" \
        --head "$EXPECTED_HEAD_SHA" \
        --pr "$PR_NUMBER" \
        --relation same-repo \
        --mode repair \
        --output "$trusted_scope"
      [ "$(node -p "JSON.parse(require('fs').readFileSync('$trusted_scope','utf8')).baseSha")" = "$COMPARISON_BASE_SHA" ]
      attest_args=()
      patch_count="$(node -p "JSON.parse(require('fs').readFileSync('/tmp/gh-aw/security-findings.json','utf8')).patch.length")"
      if [ "$patch_count" -gt 0 ]; then
        node "$trusted_validator" stage-repair \
          --report /tmp/gh-aw/security-findings.json \
          --source "$source_workspace" \
          --target "$trusted_workspace"
        cargo test --manifest-path tools/wta/Cargo.toml
        attest_args+=(--wta-tests-passed)
      fi
      node "$trusted_validator" attest \
        --report /tmp/gh-aw/security-findings.json \
        --head "$EXPECTED_HEAD_SHA" \
        --output "$trusted_report" \
        "${attest_args[@]}"
      node "$trusted_validator" validate \
        --scope "$trusted_scope" \
        --report "$trusted_report" \
        --validated /tmp/gh-aw/security-findings.validated.json \
        --summary /tmp/gh-aw/security-summary.md \
        --status /tmp/gh-aw/security-status.txt
      node "$trusted_validator" validate-output \
        --validated /tmp/gh-aw/security-findings.validated.json \
        --agent-output /tmp/gh-aw/agent_output.json
      git diff --binary HEAD > /tmp/gh-aw/security-repair.patch
      popd
      cp "$trusted_scope" /tmp/gh-aw/security-scope.validated.json
      cat /tmp/gh-aw/security-summary.md >> "$GITHUB_STEP_SUMMARY"

  - name: Upload validated security repair report
    if: always()
    uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
    with:
      name: ghaw-pr-security-${{ github.event.inputs.pr_number }}-${{ github.event.inputs.expected_head_sha }}
      path: |
        /tmp/gh-aw/security-scope.validated.json
        /tmp/gh-aw/security-findings.validated.json
        /tmp/gh-aw/security-summary.md
        /tmp/gh-aw/security-status.txt
        /tmp/gh-aw/security-repair.patch
      if-no-files-found: error
      retention-days: 14

timeout-minutes: 45
max-ai-credits: 800
max-daily-ai-credits: 5000

concurrency:
  group: 'ghaw-pr-security-repair-${{ github.event.inputs.pr_number }}'
  job-discriminator: ${{ github.run_id }}
  cancel-in-progress: true

run-name: 'Security Repair ${{ github.event.inputs.dispatch_id }}'
---

Same-repository security review and eligible repair for PR
#${{ github.event.inputs.pr_number }}.

Read `/tmp/gh-aw/security-scope.json`, then follow
`.github/skills/ghaw-pr-security/SKILL.md` in `repair` mode against comparison
base `${{ github.event.inputs.comparison_base_sha }}` and immutable head
`${{ github.event.inputs.expected_head_sha }}`.

Review every applicable changed trust boundary. Only a HIGH/high-confidence
finding with strong repository evidence, a minimal allowlisted patch, passing
applicable validation against the final patch, and independent review `PASS`
may be marked `fixed`.

For a proposed repair, invoke the registered `ghaw-pr-security-reviewer` after the
final validation. Give it the comparison base, immutable original head, exact
finding, final diff, SHA-256 of `git diff --binary HEAD`, and command/exit
evidence. Record that exact digest and immutable head in the review result. Do
not publish if it does not return explicit `PASS` for both.

Write `/tmp/gh-aw/security-findings.json` exactly as the skill specifies and
list every modified path in `patch`. Call `noop` exactly once whether or not a
validated patch exists. Never publish code or add a PR comment: the trusted
controller consumes the validated artifact and performs the mutually exclusive
fast-forward repair or guidance-comment operation. Remaining HIGH findings stay
blocking with a concrete reason.

## agent: `ghaw-pr-security-reviewer`
---
description: Independently verifies a proposed security finding and repair
tools: ['read', 'search', 'execute']
---

Re-derive the original finding from the immutable comparison-base/head patch,
then inspect the proposed final patch and validation evidence. Do not trust the
repair agent's severity, confidence, selected lines, or summary. Return `PASS`
only when every claimed fixed finding is HIGH/high-confidence, the original
regression is proven, the patch is minimal and preserves intended behavior, the
applicable final validation passed, no lower-severity issue was edited, and no
new security regression was introduced. Otherwise return `FAIL` with concise,
non-secret findings. Do not edit or publish.
## end agent: `ghaw-pr-security-reviewer`
