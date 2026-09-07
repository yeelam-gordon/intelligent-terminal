---
name: ensure-localization
description: 'Shared localization workflow for Intelligent Terminal. Use when reviewing or repairing src/cascadia Resources .resw files or tools/wta/locales/*.yml, running deterministic localization Gate or Validate checks, preparing fork guidance, or invoking the Localization Expert/Reviewer agents.'
---

# Ensure Localization

Use this skill as the single process authority for Intelligent Terminal
localization work. It owns the reusable repair/review flow, the deterministic
checker path, and the output contract for same-repo repair, read-only review,
and fork guidance.

## When to Use This Skill

- Pull requests or edits touch `src/cascadia/**/Resources/*.resw`.
- Pull requests or edits touch `tools/wta/locales/*.yml`.
- You need to run deterministic localization gate or validation checks.
- You are acting as the `Localization Expert` or `Localization Reviewer`.
- You need to prepare a fork-safe localization guidance card without checking
  out untrusted fork content.

## Owned Files

- Deterministic checker:
  [`./scripts/localization_checks.ps1`](./scripts/localization_checks.ps1)
- Checker-only unit tests:
  [`./tests/LocalizationChecks.Tests.ps1`](./tests/LocalizationChecks.Tests.ps1)
- Same-repo workflow source:
  [`../../workflows/ensure-localization.md`](../../workflows/ensure-localization.md)
- Fork guidance workflow source:
  [`../../workflows/ensure-localizationguide-forkedrepo.md`](../../workflows/ensure-localizationguide-forkedrepo.md)

## Source Authority and Edit Scope

- `src/cascadia/**/Resources/en-US/*.resw` and direct
  `src/cascadia/**/Resources/*.resw` entries are the source-language authority
  for `.resw`.
- `tools/wta/locales/en-US.yml` is the source-language authority for WTA
  locale files.
- **Do not change `en-US` or other source-language strings just to make a
  translation pass.** Change source text only when the caller explicitly
  changes customer-facing English copy.
- Discover locale sets from the repository. Never hardcode locale counts.
- Update every locale file the component already ships, including
  `qps-ploc`, `qps-ploca`, and `qps-plocm`.
- Do not add a new locale file for a component that does not already ship it.
- Keep changes surgical: touch only the reported localization files, resources,
  and directly required translator comments.

## Format Rules

### `.resw` resource files

- Keep files well-formed XML.
- Preserve the existing UTF-8 BOM. New `.resw` files must be UTF-8 with BOM.
- Preserve `xml:space="preserve"`, resource names, comments, and unaffected
  ordering.
- Use XML-aware or byte-preserving edits. Never do line-oriented text rewrites
  of `.resw` payloads.
- Ambiguous user-facing strings need translator comments.

### `tools/wta/locales/*.yml`

- Keep the existing flat `key: "value"` structure. Do not introduce nested
  YAML objects.
- Preserve UTF-8 text, comments, section headers, and neighboring ordering.
- YAML comments are translator guidance and are part of the contract.
- Avoid ad-hoc YAML rewrites that can drop comments or change scalar meaning.

## Locked Content, Placeholders, and Pseudo-Locales

- `{Locked}` means the value must stay identical to the source.
- `{Locked="token"}` or `{Locked="token1","token2"}` preserves verbatim tokens
  inside localized text.
- Locale-scoped locks such as `{Locked=qps-ploc,qps-ploca,qps-plocm}` apply
  only to the listed locales.
- Preserve placeholders exactly, including `{0}` and `%{agent}`-style tokens.
- Lock brand names and technical tokens that should not be translated,
  including `ACP`, `CLI`, `Copilot`, `Claude`, `Codex`, `Gemini`, `Hooks`,
  `JSON`, `OpenCode`, `PATH`, `PowerShell`, `XML`, and `YAML`.
- Preserve pseudo-locale style:
  - `qps-ploc` uses the established bracketed/accented style.
  - `qps-ploca` uses the `[!!_..._!!]` wrapper style.
  - `qps-plocm` uses the `[!! ... !!]` mirrored or mnemonic style.
- A translatable pseudo-locale value must not remain identical to `en-US`
  unless the source is fully locked for that locale.

## Terminology Alignment

Use terminology sources in this order:

1. Existing `.resw` translations in this repository.
2. Existing `tools/wta/locales/*.yml` translations for the same locale.
3. Microsoft Learn localized terminology.
4. Broader community usage only when repository and Microsoft sources are
   silent.

When a native-language term implies the wrong concept, keep the English term or
use a well-established transliteration instead.

## Deterministic Checker Contract

The only checked-in deterministic localization gate is
[`./scripts/localization_checks.ps1`](./scripts/localization_checks.ps1).

Run it with repository-relative paths:

```powershell
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Gate -PullRequestNumber 13 -BaseRevision <base-sha> -HeadRevision <head-sha>
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha>
```

- `Gate` mode decides whether customer-facing semantics changed enough to
  require review. It intentionally ignores BOM, EOL, comment, order, and
  formatting-only churn.
- `Validate` mode owns deterministic checks such as XML or UTF-8 parsing, BOM
  preservation, locale/key parity, placeholder parity, locked-token
  preservation, and pseudo-locale shape.
- The script writes JSONL to stdout. The final line is the summary record.
- Translation quality, tone, and terminology judgment still require reviewer or
  expert judgment.

## Same-Repo Expert Flow

Use this flow when edits are allowed:

1. Run `Validate` before editing and treat the checker as authoritative.
2. If the result is `FIXABLE`, repair only the reported files and resources.
3. Re-run `Validate` after the repair.
4. If the result is `BLOCKED` or an invalid-input summary, stop and surface the
   exact `check_id`, file, resource, observed value, expected value, and
   suggested action.
5. After deterministic validation passes, invoke one independent read-only
   reviewer pass.
6. If the reviewer returns `PASS` and no edits were required, emit exactly one
   visible `add_comment` safe output for the PR. The comment must report the
   source keys, the applicable locale count, the validations that passed, and
   the literal review outcome lines `Independent Localization Reviewer: PASS`
   and `No localization changes were required.` Do not use `noop` for this
   same-repo no-change success path, and make no commit.
7. If edits were required, create one focused completion commit whose subject
   ends exactly with `[localization-expert]`.
8. When a safe-output push is used, set its `message` so the first line exactly
   matches `git log -1 --pretty=%s`, including `[localization-expert]`.

## Read-Only Reviewer Flow

Use this flow when reviewing without edits:

- Stay read-only. Do not edit, stage, commit, or push files.
- Run `Validate` when the caller provides immutable git objects or a safe local
  comparison target.
- If the review is API-only, do not claim checks that require unavailable file
  bytes or whole-tree content.
- If the checker exits `64`, surface the blocked invalid-input summary instead
  of treating it as an unexpected failure.
- Return only:
  - `PASS` with concise evidence, or
  - `FAIL` with actionable findings.
- Every failure must cite `check_id`, file, resource, observed problem,
  expected result, and suggested action.

## Fork Guidance Rules

- Never check out or execute untrusted fork source objects just to inspect
  localization content.
- Use trusted base content plus immutable git objects or pull-request APIs.
- If `Gate` or `Validate` says no relevant customer-facing semantics changed,
  post no contributor comment.
- If deterministic findings are `FIXABLE`, post one concise card that links
  this skill and only the applicable wrapper instructions for the changed file
  types.
- If validation is blocked, fail honestly with the blocked summary and do not
  post a misleading success or repair comment.

## Gotchas

- **Do not duplicate this procedure elsewhere.** The skill is the reusable
  workflow authority; instruction wrappers stay thin and agent files stay
  role-only.
- **Do not invent locked-token fixes.** If the source string is fully locked,
  the target must match it exactly.
- **Do not translate `en-US` to repair locale-only issues.** Fix the localized
  files instead.
- **Do not skip the independent reviewer.** Deterministic validation does not
  replace final translation review.
