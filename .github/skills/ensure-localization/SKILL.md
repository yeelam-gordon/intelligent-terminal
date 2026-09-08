---
name: ensure-localization
description: 'Reusable localization guidance for Intelligent Terminal. Use for customer-facing `.resw` resources or flat locale YAML, terminology consistency across UI and WTA, deterministic Gate or Validate checks on the repo''s automated paths, and read-only or repair localization review.'
---

# Ensure Localization

Use this skill for reusable localization principles and the deterministic checker contract. The caller owns runtime context: whether the work is same-repo repair, read-only review, or fork guidance, plus any trusted revisions, changed paths, or safe-output requirements.

## When to Use This Skill

- Review or repair customer-facing localized `.resw` resources.
- Review or repair flat locale YAML used as translated strings, not arbitrary configuration YAML.
- Keep wording consistent within a locale and across `.resw` plus WTA locale YAML for the same locale.
- Run deterministic localization `Gate` or `Validate` checks for the repo's current automated scope.
- Act as the `Localization Expert` or `Localization Reviewer`.

## Scope and Caller Context

- This skill can guide localized `.resw` and flat locale YAML work in this repo beyond today's workflow allowlists.
- The checked-in automation, wrappers, and deterministic checker currently target only:
  - `src/cascadia/**/Resources/*.resw`
  - `src/cascadia/**/Resources/**/*.resw`
  - `tools/wta/locales/*.yml`
- Do not claim script coverage for other YAML shapes or arbitrary configuration files. Those still need agent judgment unless the checker is extended.
- The caller decides whether the task is same-repo repair, read-only review, or fork guidance.
- The caller supplies the trusted base or head revisions, workspace state, or changed-file list needed for validation.
- When same-repo repair validation must preserve the reviewed source authority in a mutable worktree, the caller supplies `ReviewedHeadRevision`.
- When automation expects a visible safe output, the caller supplies that channel and any message-shape requirements.

## Source Authority and Edit Scope

- Source-language authority for `.resw` is `src/cascadia/**/Resources/en-US/*.resw` plus direct `src/cascadia/**/Resources/*.resw` source entries.
- Source-language authority for WTA locale YAML is `tools/wta/locales/en-US.yml`.
- Do not change `en-US` or another source-language string just to make a translation pass.
- Discover locale sets from what the component already ships; do not hardcode locale counts.
- Update every shipped locale for the affected component, including `qps-ploc`, `qps-ploca`, and `qps-plocm`, but do not add brand-new locale files.
- Keep edits surgical: only the reported localization entries and directly required translator guidance.

## Format Rules

### `.resw`

- Keep files well-formed XML.
- Preserve the existing UTF-8 BOM. New `.resw` files must be UTF-8 with BOM.
- Preserve `xml:space="preserve"`, resource names, comments, and unaffected ordering.
- Use XML-aware or byte-preserving edits. Never rewrite `.resw` values with line-oriented text tooling.
- Add translator comments when the user-facing English is ambiguous.

### Flat locale YAML

- Keep the existing flat `key: "value"` locale structure.
- Preserve UTF-8 text, comments, section headers, and neighboring ordering.
- YAML comments are translator guidance and part of the localization contract.
- Avoid rewrites that can drop comments or change scalar meaning.
- These YAML rules are for translated locale content, not arbitrary configuration YAML.

## Locked Content, Placeholders, and Pseudo-Locales

- Preserve placeholders exactly in every format, including `{0}` and `%{agent}`-style tokens.
- `{Locked}` means the localized value must stay identical to the source.
- `{Locked="token"}` or `{Locked="token1","token2"}` preserves verbatim tokens
  inside localized text.
- Locale-scoped locks such as `{Locked=qps-ploc,qps-ploca,qps-plocm}` apply
  only to the listed locales.
- In `.resw`, read lock directives from translator comments on the source entry; in flat locale YAML, read them from the source YAML comments attached to the key.
- Keep brand names and technical tokens untranslated when the source marks or clearly treats them as fixed product terms, including `ACP`, `CLI`, `Copilot`, `Claude`, `Codex`, `Gemini`, `Hooks`, `JSON`, `OpenCode`, `PATH`, `PowerShell`, `XML`, and `YAML`.
- Preserve each format's established pseudo-locale style instead of forcing one format's wrapper onto another:
  - `tools/wta/locales/*.yml`: `qps-ploc` bracketed or accented style,
    `qps-ploca` `[!!_..._!!]`, `qps-plocm` `[!! ... !!]`
  - `.resw`: keep the pseudo-locale form already shipped by that component; preserve its existing placeholders, locked content, and style
- A translatable pseudo-locale value must not remain identical to the source unless the source is fully locked for that locale.

## Consistency and Terminology

- Keep terminology consistent within each locale across strings, phrases, and sentences.
- Keep terminology equally consistent across `.resw` and flat locale YAML for the same locale; they are the same product surface.
- Reuse existing repository translations before inventing new wording.
- Resolve terms in this order:
  1. Existing `.resw` translations in this repository.
  2. Existing `tools/wta/locales/*.yml` translations for the same locale.
  3. Microsoft Learn localized terminology.
  4. Wider established usage only when repository and Microsoft sources are silent.
- If a native-language term would imply the wrong product concept, keep the English term or use a well-established transliteration instead.

## Deterministic Checker Contract

The checked-in deterministic checker is [`./scripts/localization_checks.ps1`](./scripts/localization_checks.ps1). It currently automates only the repo paths listed in
[Scope and Caller Context](#scope-and-caller-context).

Use repository-relative commands that match the caller's context:

```powershell
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Gate -PullRequestNumber <pr-number> -BaseRevision <base-sha> -HeadRevision <head-sha>
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha>
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha> -ReviewedHeadRevision <reviewed-head-sha>
```

- `Gate` decides whether customer-facing semantics changed enough to require review and ignores BOM, EOL, comment, order, and formatting-only churn.
- `Validate` performs deterministic parsing and parity checks for the automated scope, including XML or UTF-8 parsing, BOM preservation, locale/key parity, placeholder parity, locked-token preservation, and pseudo-locale shape.
- `ReviewedHeadRevision` is only for mutable-worktree `Validate` runs that must keep reviewed source-language content authoritative.
- The script writes JSONL to stdout; the final line is the summary record.
- Translation quality, tone, and terminology judgment still require reviewer or expert judgment.

## Review and Repair Contract

### Same-Repo Repair

- Run `Validate` before editing and treat its findings as authoritative for deterministic issues.
- Repair only the reported localization files and resources, then re-run `Validate`. When validating a mutable worktree against an immutable reviewed source authority, pass `-ReviewedHeadRevision <reviewed-head-sha>`.
- If validation returns `BLOCKED` or invalid input, stop and surface the exact `check_id`, file, resource, observed value, expected value, and suggested action.
- After deterministic validation passes, run one independent read-only reviewer pass.
- If no edits were required and the caller's safe-output contract expects a visible success, use `add_comment`; do not substitute `noop`.
- If edits were required, create one focused completion commit whose subject ends exactly with `[localization-expert]`.
- When the caller's automation pushes a safe-output message, make its first line exactly match `git log -1 --pretty=%s`, including `[localization-expert]`.

### Read-Only Review

- Stay read-only: do not edit, stage, commit, or push.
- Run `Validate` only when the caller provides immutable git objects or a safe local comparison target.
- If the review is API-only, do not claim checks that require unavailable file bytes or whole-tree content.
- If the checker exits `64`, surface the blocked invalid-input summary instead of treating it as an unexpected failure.
- Return only `PASS` with concise evidence or `FAIL` with actionable findings.
- Every failure must cite `check_id`, file, resource, observed problem, expected result, and suggested action.

### Fork Guidance

- Never check out or execute untrusted fork source objects just to inspect localization content.
- Use trusted base content plus immutable git objects or pull-request APIs.
- If `Gate` or `Validate` says no relevant customer-facing semantics changed, post no contributor comment.
- If deterministic findings are `FIXABLE`, post one concise guidance card that links this skill and only the applicable wrapper instructions for the changed file types.
- If validation is blocked, fail honestly with the blocked summary and do not post a misleading success or repair comment.

## Gotchas

- **The caller, not the skill, decides runtime situation.** Do not infer fork vs. same-repo vs. read-only from the skill alone.
- **Current automation allowlists are narrower than the skill.** Do not claim the checker parses arbitrary YAML or unsupported localization file shapes.
- **Do not invent locked-token fixes.** If the source string or token is locked, preserve it exactly.
- **Do not change source-language text to repair locale-only issues.** Fix the localized files instead.
- **Do not skip the independent reviewer.** Deterministic validation does not
  replace final language review.
