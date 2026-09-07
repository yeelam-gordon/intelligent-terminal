---
applyTo: "src/cascadia/**/Resources/*.resw, src/cascadia/**/Resources/**/*.resw"
---

# Localization Instructions for `.resw` Resource Files

## Scope and source of truth

- Localizable `.resw` files live under `src/cascadia/**/Resources/`.
- Treat these as source-language resources:
  - `src/cascadia/**/Resources/en-US/*.resw`
  - direct `src/cascadia/**/Resources/*.resw`
- The locale folders already present under each component are authoritative.
  Discover them from the repository; never hardcode a locale count.
- `tools/wta/locales/*.yml` must stay aligned with the same locale set.

## Updating localized `.resw` files

- Compare source-language entries first and update only the affected keys.
- Update every locale file that already exists for that component.
- Always update `qps-ploc`, `qps-ploca`, and `qps-plocm`, but keep their values as
  English fallback text rather than pseudo-translating them.
- Do not add a component-localized file for a locale that component does not
  already ship.
- For multi-locale edits, batch the whole change with one deterministic,
  XML-aware script. Do not spend one top-level turn or one tool call per locale.

## File-format rules

- `.resw` files must remain well-formed XML.
- Preserve the existing UTF-8 BOM. New `.resw` files must be written with a BOM.
- Preserve `xml:space="preserve"`, resource names, comments, and unaffected
  entry ordering.
- Never use plain text replacement or line-oriented editors to rewrite `.resw`
  payloads. Use an XML-aware or byte-preserving script.

## Translator guidance and locked content

- Every ambiguous user-facing string needs a translator comment explaining the UI
  context or meaning.
- Use `{Locked}` when the entire value must stay identical to English.
- Use `{Locked="token"}` or `{Locked="token1","token2"}` when specific terms
  must remain verbatim inside a translated string.
- Lock brand names and technical tokens that should not be translated, including:
  `ACP`, `CLI`, `Copilot`, `Claude`, `Codex`, `Gemini`, `Hooks`, `JSON`, `OpenCode`,
  `PATH`, `PowerShell`, `XML`, and `YAML`.
- Preserve runtime placeholders exactly, including numbered placeholders such as
  `{0}` and named placeholders such as `%{agent}`.

## Terminology alignment

Use these sources in order:

1. Existing `.resw` translations in this repository.
2. Existing `tools/wta/locales/*.yml` translations for the same locale.
3. Microsoft Learn localized terminology.
4. Broader community usage only when the repository and Microsoft sources do not
   establish the term.

When a native-language term would imply the wrong concept, keep the English term
or use a well-established transliteration instead.

## Deterministic validation contract

- `.github/scripts/localization_checks.ps1` is the only checked-in deterministic
  gate and validation script for localization workflows.
- `Gate` mode decides whether customer-facing semantics changed enough to require
  review. It intentionally ignores BOM, EOL, comment, order, and formatting-only
  churn.
- `Validate` mode owns deterministic checks such as XML parsing, BOM
  preservation, key parity, placeholder parity, and locked-token preservation.
- Translation quality, tone, and terminology judgment stay with the reviewer or
  expert agent; the script does not replace human or model review.
