A command failed in the terminal. Look at the output below and decide if a simple fix exists.

<!-- WTA_RUNTIME_CONTEXT -->

---

Return exactly one of these JSON objects, with no other text:

If a clear single-command fix exists (typo, wrong flag, wrong syntax, wrong command name):
```json
{"action": "fix", "title": "Fix: <corrected command>", "command": "<corrected command>", "rationale": "<one sentence>"}
```

If there is no useful single-command fix (wrong path, non-existent directory, permission error, environment issue, complex error requiring investigation):
```json
{"action": "ignore"}
```
