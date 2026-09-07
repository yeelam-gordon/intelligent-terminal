---
applyTo: "tools/wta/locales/*.yml"
---

# Localization Instructions for Rust WTA Locale Files

## Scope and source of truth

- WTA locales live in `tools/wta/locales/*.yml`.
- `tools/wta/locales/en-US.yml` is the source of truth for WTA strings.
- The WTA locale file set must match the locale folders under
  `src/cascadia/TerminalApp/Resources/`; discover that set from the repository,
  never from a hardcoded list.
- Locale files are flat key/value maps. Do not introduce nested YAML objects.

## Updating WTA locale files

- Add, change, and remove keys in `en-US.yml` first.
- Apply the same key change to every locale file, including the pseudo-locales.
- Batch multi-locale edits with one deterministic script; do not drive one
  top-level action per locale.
- Preserve unaffected comments, section headers, and neighboring ordering.

## File-format rules

- WTA locale files are UTF-8 text.
- Keep the existing flat `key: "value"` structure.
- Keep comments that explain UI context, placeholders, or locked terms.
- Avoid ad-hoc YAML rewrites that can drop comments or change scalar meaning.

## Locked terms and translator context

- YAML comments are authoritative for translator guidance.
- Support the three existing scopes:
  - file-level comments,
  - section-level comments,
  - inline per-entry comments.
- `{Locked}` means the full value stays identical to English.
- `{Locked="token"}` preserves one or more verbatim tokens inside a localized
  string.
- Locale-scoped locks such as `{Locked=qps-ploc,qps-ploca,qps-plocm}` are used
  when pseudo-locales must preserve an English token that real locales may
  translate.
- Ambiguous or short UI strings need a context comment.
- Preserve runtime placeholders exactly, especially `%{name}`-style tokens.

## Pseudo-locales

- `qps-ploc` must keep the established bracketed/accented style.
- `qps-ploca` must keep the `[!!_..._!!]` wrapper style.
- `qps-plocm` must keep the `[!! ... !!]` mirrored/mnemonic style.
- A translatable value must not remain identical to `en-US` in a pseudo-locale
  unless the source is fully locked for that locale.

## Terminology alignment

Use these sources in order:

1. Existing `.resw` translations in this repository.
2. Existing WTA locale files for the same language.
3. Microsoft Learn localized terminology.
4. Community usage only when repository and Microsoft sources are silent.

## Deterministic validation contract

- `.github/scripts/localization_checks.ps1` is the only checked-in deterministic
  localization validator used by the workflows.
- `Gate` mode ignores comment, order, BOM, EOL, and formatting-only churn and
  looks only at key/value semantic changes.
- `Validate` mode owns deterministic checks such as UTF-8 parsing, key parity,
  placeholder parity, locked-token preservation, and pseudo-locale shape.
- Reviewers still judge translation quality and terminology choices; the script
  only enforces deterministic rules.
