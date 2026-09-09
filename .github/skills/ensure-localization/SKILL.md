---
name: ensure-localization
description: 'Inspect, author, repair, and review customer-facing RESW and localization YAML resources. Use shared product terminology, translator context, lock annotations, and six file-based checks; the caller supplies the goal and scope.'
---

# Ensure Localization

Use this shared procedure for customer-facing localization. The caller supplies
the goal, scope, and permitted edits; PR or workflow context is not required.

## Product consistency

Keep terminology consistent within each locale and across RESW and localization
YAML for the same product. Grammar may vary with context, but established product
keywords should not alternate between unrelated translations.

## Caller context

The caller owns repository or PR context, trusted revisions, skip policy,
automation allowlists, and safe-output rules. This skill owns only the reusable
file-based localization procedure.

## Resources

- File checker: [`./scripts/localization_checks.ps1`](./scripts/localization_checks.ps1)

## Supported files

The skill applies to localization resources regardless of their location. The
checker supports `.resw` and flat locale `.yml` files; other YAML structures need
an appropriate parser, not conversion merely to satisfy this checker.

Discover source and target files using the caller's context and existing layout.
In this repository, `en-US` files and direct resource files are common source
authorities; these are conventions, not mandatory checker paths.

Do not edit source-authority files just to make translations pass.

## Source-authoring guidance

- Add translator context when wording is ambiguous or depends on UI usage, such
  as a noun versus a command. Explain the meaning and placeholder roles; avoid
  boilerplate comments for obvious strings.
- Use `{Locked}` when the whole value must remain literal, and
  `{Locked="token"}` for invariant parts such as product names, protocol names,
  commands, or paths. Use locale-scoped locks only when the exception genuinely
  applies to those locales; do not exempt entire pseudo-locales by default.
- Put guidance in the resource's `<comment>` for RESW or its associated YAML
  comment. Preserve annotations in target files where the format requires them.
- When source edits are not permitted, report missing or contradictory source
  guidance instead of silently changing source files or inventing meaning.
  Mechanical checks preserve declared locks; they cannot decide which
  annotations a new string needs.

## Six checks

| Check | Required args | Purpose |
| --- | --- | --- |
| `Test-ResourceSyntax` | `-File` | Parse supported XML or flat locale YAML shape |
| `Test-ResourceEncoding` | `-File` (`-OriginalFile` optional) | Enforce UTF-8 and expected BOM behavior |
| `Test-RequiredKeys` | `-SourceFile -TargetFile` (`-Keys` optional for PowerShell callers; CLI uses `-KeysJson` when scoping) | Missing and stale key parity |
| `Test-PlaceholderParity` | `-SourceFile -TargetFile` (`-Keys` optional for PowerShell callers; CLI uses `-KeysJson` when scoping) | Placeholder identity and count parity |
| `Test-LockedContent` | `-SourceFile -TargetFile` (`-Locale` sometimes required, `-Keys` optional for PowerShell callers; CLI uses `-KeysJson` when scoping) | Preserve locked values and tokens |
| `Test-PseudoLocale` | `-SourceFile -TargetFile -Locale` (`-Keys` optional for PowerShell callers; CLI uses `-KeysJson` when scoping) | Catch English fallback and pseudo-style mistakes |

Example commands:

```powershell
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-ResourceSyntax -File <file>
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-ResourceEncoding -File <file> [-OriginalFile <original-file>]
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-RequiredKeys -SourceFile <source-file> -TargetFile <target-file> [-KeysJson '["key1","key2"]']
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-PlaceholderParity -SourceFile <source-file> -TargetFile <target-file> [-KeysJson '["key1","key2"]']
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-LockedContent -SourceFile <source-file> -TargetFile <target-file> [-Locale <locale>] [-KeysJson '["key1","key2"]']
pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Check Test-PseudoLocale -SourceFile <source-file> -TargetFile <target-file> -Locale <pseudo-locale> [-KeysJson '["key1","key2"]']
```

The script writes one JSON bundle to stdout and exits with the actual status
mapping:

- `0` → `PASS`
- `20` → `FIXABLE`
- `30` → `BLOCKED`
- `64` → `INVALID_INPUT`

## Native final-report handoff

When a caller specifies a final checker report path, collect bundles from actual
CLI invocations of `localization_checks.ps1`; never fabricate bundle fields or
convert human conclusions into checker JSON. Keep initial failing attempts out of
the final report. After repairs and any required independent review, write only
the final rerun bundles using the caller's exact envelope and path. The caller's
native post-step owns structural validation and write gating.

## Reusable procedure

1. Use normal git inspection against the caller-supplied comparison base and
   head to determine the actual PR review scope.
   - Source-authority add or update: expand to every shipped localized
     counterpart that should carry the affected file or keys, even when those
     target files are unchanged in the git diff.
   - Target-only edit: inspect that localized target against its source
     authority.
   - Source key or file removal: inspect obsolete shipped counterparts with
     ordinary git and file review. Handle removal or cleanup explicitly instead
     of claiming `PASS` because no file-pair check ran.
2. Map each localized target to its source-authority file. In this repository,
   `.resw` targets map to `.../Resources/en-US/*.resw` or direct
   `.../Resources/*.resw`, and WTA locale targets map to
   `tools/wta/locales/en-US.yml`.
3. Before translating changed terms, inspect existing translations in the same
   locale across both `.resw` files and `tools/wta/locales/*.yml`. Reuse
   established product terminology when the meaning and UI context match. If no
   repository precedent exists, prefer Microsoft localized terms and flag
   conflicting existing translations instead of inventing synonyms or rewriting
   unrelated strings.
4. Use `-Keys` only for native PowerShell function calls, or `-KeysJson` when
   invoking the checker script from the CLI. Optional key scoping exists to
   avoid fixing unrelated old debt, not to hide source additions that the
   procedure already put in scope. Omit the scope parameter entirely for a
   whole-file check.
5. Run `Test-ResourceSyntax` and `Test-ResourceEncoding` on every file you
   actually inspect.
6. For each localized target, run `Test-RequiredKeys`,
   `Test-PlaceholderParity`, `Test-LockedContent`, and, for pseudo-locales,
   `Test-PseudoLocale` against the matching source-authority file.
7. Same-repo repair: run the checks before editing, repair only localized
   targets, rerun the same relevant checks, then finish with one independent
   read-only review before requesting any branch write.
8. Read-only review or fork guidance: stay read-only; report only the actual
   `PASS`, `FIXABLE`, `BLOCKED`, or `INVALID_INPUT` outcomes plus concise human
   review.

## Gotchas

- The public checker API is file-only. Do not pass PR numbers, SHAs, repo
  names, comparison-base discovery, or workflow `Mode` values.
- `Test-RequiredKeys` can report missing entries and stale keys for a provided
  source/target file pair, but it does not discover which untouched locale
  files or deleted source-file counterparts must be inspected. The caller or
  agent must do that repository discovery.
- `Test-SourceUnchanged`, `Gate`, and `Validate` are intentionally gone. Skip
  decisions such as “formatting-only, do not spend AI” belong to the
  caller/workflow.
- `Test-ResourceEncoding` is the only check that reasons about BOM
  preservation. Keep source-preservation and safe-write policy in the caller,
  and supply `-OriginalFile` whenever a comparison snapshot exists.
- When you invoke `localization_checks.ps1` from `pwsh -File`, use `-KeysJson`
  for scoped keys. `-Keys key1,key2` is ambiguous at the CLI layer and is not
  the supported script interface.
- A source-only, blocked, or excluded-file result is not a successful repair.
  Comment or fail honestly instead of pretending `PASS`.
