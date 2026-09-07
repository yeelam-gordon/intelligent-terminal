---
applyTo: "src/cascadia/**/Resources/*.resw, src/cascadia/**/Resources/**/*.resw"
---

# Localization Instructions for .resw Resource Files

## Overview

This project uses `.resw` (XML resource) files for localization. Resources live under each component's `Resources/{locale}/*.resw` path.

> **Important:** The set of locale folders is the authoritative source for how many languages we support. Never hardcode the count — discover it dynamically from the folders. The Rust WTA project (`tools/wta/locales/*.yml`) must always match this same set.

### Common components with localized resources

This list is non-exhaustive; discover all applicable components through the
resource globs rather than maintaining a fixed component allowlist.

| Component | Path |
|-----------|------|
| TerminalApp | `src/cascadia/TerminalApp/Resources/` |
| TerminalSettingsModel | `src/cascadia/TerminalSettingsModel/Resources/` |
| TerminalSettingsEditor | `src/cascadia/TerminalSettingsEditor/Resources/` |
| TerminalConnection | `src/cascadia/TerminalConnection/Resources/` |
| TerminalControl | `src/cascadia/TerminalControl/Resources/` |
| UIHelpers | `src/cascadia/UIHelpers/Resources/` |
| Remoting | `src/cascadia/Remoting/Resources/` |
| CascadiaPackage | `src/cascadia/CascadiaPackage/Resources/` |

### Locale categories

- **Major translation locales** — have full translations for TerminalApp, TerminalSettingsModel, and TerminalSettingsEditor (e.g., `de-DE`, `ja-JP`, `zh-CN`, etc.)
- **Pseudo-locales** — `qps-ploc`, `qps-ploca`, `qps-plocm` — use English fallback text (not real translations)
- **Component-limited locales** — only update components that already contain a resource file for that locale

To determine the full locale set:

```powershell
# Authoritative locale list (from TerminalApp)
Get-ChildItem "src/cascadia/TerminalApp/Resources/" -Directory | Select-Object -ExpandProperty Name
```

## Adding or Updating Localized Strings

### Step 0: Discover what needs localization

Before translating, determine which strings are new or changed:

```powershell
# Compare en-US keys against a locale to find missing keys
$enUS = [xml](Get-Content "src/cascadia/TerminalApp/Resources/en-US/Resources.resw")
$target = [xml](Get-Content "src/cascadia/TerminalApp/Resources/zh-CN/Resources.resw")
$enKeys = $enUS.root.data | ForEach-Object { $_.name }
$targetKeys = $target.root.data | ForEach-Object { $_.name }
$missing = $enKeys | Where-Object { $_ -notin $targetKeys }
$missing  # Keys that need translation
```

For changed strings, diff against main:

```powershell
git diff main -- src/cascadia/TerminalApp/Resources/en-US/Resources.resw
```

Repeat for each component.

### Step 1: Determine the target locale set

The locale set is **not hardcoded**. Derive it from the locale folders:

```powershell
# List all locale folders (this is the authoritative set)
Get-ChildItem "src/cascadia/TerminalApp/Resources/" -Directory | Select-Object -ExpandProperty Name
```

- If a key is a brand name / technical identifier / format string → mark `{Locked}` and copy verbatim to **all** locales
- If a key contains user-visible text → translate to all **major** locales (those with full Resources.resw for that component)
- Always add to pseudo-locales (`qps-ploc`, `qps-ploca`, `qps-plocm`) with the English fallback text
- Do NOT add to minor locales unless they already have a `Resources.resw` for that component

### Step 2: Translate to all locales

For each target language:
1. Read the en-US source strings (only the new/changed keys from Step 0)
2. Read existing translations in the target locale for tone/style consistency
3. Follow the [Terminology Alignment](#terminology-alignment) process for term choices
4. Follow the [Resource Comments](#resource-comments) rules — locked tokens must appear verbatim

Apply the reviewed translation map to all target `.resw` files with one
XML-aware, byte-preserving Python or Node script. Do not use one top-level agent
turn, tool call, or sub-agent invocation per locale; the full locale set exceeds
bounded automation budgets. Interactive workflows may use language specialists
to research uncertain terminology, but file updates must remain batched and
deterministic.

### Step 3: QA review

Use an independent reviewer sub-agent to check every affected language for:
- **`{Locked}` tokens** preserved verbatim (see [Resource Comments](#resource-comments))
- **Terminology** aligned with existing translations (see [Terminology Alignment](#terminology-alignment))
- RTL languages have correct logical string order
- No mojibake or encoding issues
- XML well-formedness preserved

### Step 4: Validate

After modifying `.resw` files, validate XML well-formedness:

```powershell
$xml = New-Object System.Xml.XmlDocument
$xml.Load($path)  # Throws if malformed
```

## File Format Requirements

- `.resw` files are XML with **UTF-8 BOM** encoding — always save with BOM
- Use `XmlDocument` (PowerShell) or `fs.readFileSync`/`writeFileSync` (Node.js) — **never use text-based edit tools** on `.resw` files (they corrupt XML)
- Node.js is more reliable than PowerShell for CJK content (PowerShell 5.1 has encoding issues with Chinese characters)
- Preserve `xml:space="preserve"` attributes — use namespace-aware setter:
  ```powershell
  $data.SetAttribute('xml:space', 'http://www.w3.org/XML/1998/namespace', 'preserve')
  ```
- Preserve BOM when using Node.js:
  ```js
  let content = fs.readFileSync(path, 'utf8');
  if (!content.startsWith('\uFEFF')) content = '\uFEFF' + content;
  fs.writeFileSync(path, content, 'utf8');
  ```

### Bulk string-replace recipe (e.g. URL sweep across all locales)

Even simple "find-and-replace this string" operations across `.resw` files **silently strip the BOM** if you use `Set-Content`, `Out-File` (without `-Encoding utf8BOM`), or any text-based edit tool. Verify BOM is preserved after every bulk edit.

**Safe PowerShell recipe** that preserves BOM and CRLF:

```powershell
$files = Get-ChildItem -Path src/cascadia/SomeComponent/Resources -Recurse -Filter Resources.resw
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $startIdx = if ($hadBom) { 3 } else { 0 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $startIdx, $bytes.Length - $startIdx)
    $newText = $text -replace 'old-pattern', 'new-pattern'
    if ($newText -eq $text) { continue }
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newText)
    if ($hadBom) { $newBytes = [byte[]](0xEF, 0xBB, 0xBF) + $newBytes }
    [System.IO.File]::WriteAllBytes($f.FullName, $newBytes)
}
```

**Verification step after any `.resw` bulk edit** (mandatory):

```powershell
foreach ($f in (git diff --name-only -- '*.resw')) {
    $b = [System.IO.File]::ReadAllBytes($f) | Select-Object -First 3
    $hasBom = $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    $orig = & cmd /c "git show HEAD:`"$f`" > `"$env:TEMP\bom-check.bin`""
    $origB = [System.IO.File]::ReadAllBytes("$env:TEMP\bom-check.bin") | Select-Object -First 3
    $origHasBom = $origB[0] -eq 0xEF -and $origB[1] -eq 0xBB -and $origB[2] -eq 0xBF
    if ($origHasBom -and -not $hasBom) { Write-Host "REGRESSED BOM: $f" }
}
```

If you see "REGRESSED BOM", restore it before committing:

```powershell
$bytes = [System.IO.File]::ReadAllBytes($path)
[System.IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF) + $bytes)
```

On Linux or in GitHub Actions, use the edit tool to save the following script as
`verify-resw.py` in the repository root. Do not create it through a shell
heredoc or output redirection. Run it, then delete it before staging so it cannot
enter the pull request:

```python
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

base = sys.argv[1]
scopes = [
    "src/cascadia/**/Resources/*.resw",
    "src/cascadia/**/Resources/**/*.resw",
]
changed = set(subprocess.check_output(
    [
        "git",
        "diff",
        "--name-only",
        "--diff-filter=ACMRT",
        base,
        "--",
        *scopes,
    ],
    text=True,
).splitlines())
changed.update(subprocess.check_output(
    ["git", "ls-files", "--others", "--exclude-standard", "--", *scopes],
    text=True,
).splitlines())

def encoding_signature(content):
    if content.startswith(b"\xef\xbb\xbf"):
        return "utf-8-bom"
    if content.startswith(b"\xff\xfe"):
        return "utf-16-le-bom"
    if content.startswith(b"\xfe\xff"):
        return "utf-16-be-bom"
    return "no-bom"

failures = []
for name in sorted(changed):
    path = Path(name)
    if not path.exists():
        continue
    content = path.read_bytes()
    current = encoding_signature(content)
    ET.fromstring(content)
    original = subprocess.run(
        ["git", "show", f"{base}:{name}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    expected = (
        encoding_signature(original.stdout)
        if original.returncode == 0
        else "utf-8-bom"
    )
    if current != expected:
        failures.append(f"{name}: expected {expected}, found {current}")

if failures:
    raise SystemExit("Encoding regressions:\n" + "\n".join(failures))
```

Run it with the supplied pull request merge-base SHA. Use this direct command
shape in restricted agentic workflows; shell heredocs may be rejected by their
command policy:

```bash
python3 verify-resw.py "$MERGE_BASE_SHA"
```

> **Why this rule exists, and why it bites:** PowerShell's default text I/O strips BOM. Any localization review that also changes resource entries must reject a BOM regression in every touched `.resw` file. The fix is mechanical but tedious. Use the safe recipe above for any bulk operation and the BOM-verification step before committing.

## Terminology Alignment

Align translations using these sources **in priority order**:

1. **Existing `.resw` translations** in this repo — ensures consistency across components
   - `src/cascadia/TerminalApp/Resources/{locale}/Resources.resw`
   - `src/cascadia/TerminalSettingsEditor/Resources/{locale}/Resources.resw`
   - `src/cascadia/TerminalSettingsModel/Resources/{locale}/Resources.resw`
2. **Existing Rust WTA translations** in `tools/wta/locales/{locale}.yml` — ensures consistency between C++ and Rust UI
3. **Microsoft Learn localized documentation** — for new terms not yet in `.resw` or `.yml`, check the official localized docs (`learn.microsoft.com/{locale}/...`) for Microsoft-standard translations

### Process

1. Before translating, check if the term already exists in `.resw` for that locale (in another component)
2. If it does → use the same translation (cross-component consistency)
3. If not in `.resw`, check if the term exists in `tools/wta/locales/{locale}.yml`
4. If still not found → check Microsoft Learn localized docs (`learn.microsoft.com/{locale}/...`)
5. If no established term exists → research community usage (Wikipedia, academic, developer forums)
6. If the native word means something unrelated to the concept → use English or a phonetic transliteration

> **Example — "Agent":** In this product, "Agent" means an AI intelligent agent (not a proxy or human agent). Apply the process above — e.g., for zh-CN, Microsoft Azure AI Foundry docs use 智能体 (NOT 代理, which means proxy). Each locale may differ; always verify against the priority sources.

## Resource Comments

The `.resw` `<comment>` element serves multiple purposes for translators. Always provide comments that help produce correct translations.

### Locked tokens

Use `{Locked}` in comments to mark content that must NOT be translated:

- **Full lock** — entire value is non-translatable:
  ```xml
  <comment>{Locked} Product name — do not translate.</comment>
  ```
- **Partial lock** — specific tokens within a translatable sentence:
  ```xml
  <comment>{Locked="Copilot","CLI"} Translate the sentence but keep these terms in English.</comment>
  ```

Terms that should always be locked:

| Term | Reason |
|------|--------|
| Hooks, Hook | Technical term (shell hooks) |
| CLI | Technical acronym |
| ACP | Technical acronym (Agent Client Protocol) |
| PATH | Environment variable |
| PowerShell | Product name |
| Copilot, Claude, Codex, Gemini, OpenCode | Brand names |
| JSON, YAML, XML | Technical formats |

### Translator guidance comments

Use comments to disambiguate meaning and prevent mistranslation:

```xml
<!-- Disambiguate a term with multiple meanings -->
<comment>Here "agent" refers to an AI intelligent agent (e.g., Copilot, Claude), not a proxy or human agent.</comment>

<!-- Explain UI context -->
<comment>This text appears as a button label in the settings page.</comment>

<!-- Clarify format placeholders -->
<comment>{0} is replaced with the profile name at runtime.</comment>
```

Good translator comments:
- Explain **which meaning** of an ambiguous word is intended
- Describe **where in the UI** the string appears (button, tooltip, title, error message)
- Document **format placeholders** (`{0}`, `{1}`, etc.) and what they represent
- Note **character length constraints** if the UI has limited space

## Common Pitfalls

| Issue | Solution |
|-------|----------|
| XML corruption | Never use text-based edit tools; use XmlDocument or Node.js |
| Missing BOM | Always save with UTF-8 BOM (`\uFEFF` prefix) |
| **Bulk string-replace strips BOM silently** | Use the [bulk string-replace recipe](#bulk-string-replace-recipe-eg-url-sweep-across-all-locales); always run the BOM-verification step before committing |
| PowerShell CJK issues | Use Node.js for Chinese/Japanese/Korean content |
| `xml:space` lost | Use namespace-aware `SetAttribute` |
| Terminology inconsistency with WTA | Check `tools/wta/locales/{locale}.yml` for that term |
