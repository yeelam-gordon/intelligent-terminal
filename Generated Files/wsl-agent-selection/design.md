# Design: source-aware agent selection

## One provider identity, one execution source

Keep `acpAgent` and `delegateAgent` as canonical provider IDs. Add
`acpAgentSource` and `delegateAgentSource`, defaulting to `host`, with
`wsl:<registered-distribution>` for an explicit WSL source. Existing settings
therefore preserve Windows behavior without migration.

Example:

```json
{
  "acpAgent": "copilot",
  "acpAgentSource": "wsl:Ubuntu",
  "delegateAgent": "claude",
  "delegateAgentSource": "host"
}
```

Reuse `AgentPaneBackend` for conversion between provider/source fields and
qualified picker/cache identities. Do not invent a second parser or overload a
provider ID with location. Append the new WinRT properties to preserve ABI.
Reject malformed explicit sources instead of treating them as Windows.
Custom command editor saves explicitly select `host`.

## Reuse the existing Settings discovery owner

Extend the existing MainPage background availability path with one all-WSL
probe. Publish an immutable value snapshot to the global and profile view
models on the UI thread. Those VMs build entries and notify bindings; XAML and
code-behind do not discover distributions, launch probes, or encode settings.

WTA owns enumeration and installed-agent detection, reusing its per-distribution
probe. Retain the existing single-distribution command for compatibility and add
an explicit all-distribution mode with bounded concurrency and a running-state
gate. Enumerating registered/running distributions does not start them; skip
executable probing for stopped distributions. Return per-source
results plus errors; do not report failed detection as authoritative absence.
Order distributions/providers deterministically.

All three surfaces use the same result: global ACP, global delegation, and
profile ACP/delegation. Existing `AgentEntry` carries a qualified selection ID;
reuse the localized `agent + location` format. Global Windows entries can keep
their bare IDs for custom-entry compatibility while displaying their location.
Keep a selected unavailable source as an explicit unavailable entry. Discovery
must not rewrite persisted settings or accidentally select a different item
while an observable list rebuilds.

For a registered but stopped/failed source, saved native-profile provider/source
metadata also supplies unavailable selectable hints. This is reused evidence,
not a claim that the CLI is still installed. A successful running-source probe
supersedes those hints. No separate persistent discovery database is needed.

## Runtime precedence and ownership

Resolve exactly once through the existing binding resolver:

```text
explicit tab selection
  > nonempty profile backend
  > global provider + global source
```

Reuse that result for both initial helper creation and settings reconciliation.
The source determines ACP launch location, not the owning terminal's profile.
Remove the obsolete same-shell restriction at the binding boundary, not
session-ownership or policy guards. Preserve exact provider/distro in helper
arguments, restore identity, process-pool keys, and session operations.

Include global source in change snapshots and request identity. A source-only
change rebinds affected global followers in place, without restarting the shared
master or retiring unrelated explicit overrides. Resolved helper/rebind metadata
always carries the exact source; master argv is only legacy fallback, not an
authorization table. Global-model inheritance requires the
same provider and source, not merely the same provider name.

Delegation resolves the same global/profile precedence and passes its explicit
source to WTA. Translate Windows cwd for WSL; reject cross-distro POSIX reuse and
resolve the target distribution's home when no trustworthy cwd is available.
Never silently fall back to a host process.

## WSL startup cost and generated profiles

Generate native WSL agent profiles through the existing dynamic agent-profile
generator, preserving stable provider-plus-distribution identities and the
separation between native profile customization and pane-managed ACP arguments.
Discovery/generation must never start a stopped VM. Only known agents from an
already-running distribution can be newly discovered. Preserve saved profile
customizations and do not manufacture an installed-agent claim for a stopped
distribution with no evidence.

Managed native agent commandlines are not interactive shells. Exclude them from
the shared WSL shell-integration snapshot so reconciliation cannot run a shell
probe or uninstall through an agent CLI. Explicit shell-command overrides keep
the existing shell-integration behavior.

Generation reads existing WSL cache immediately. The settings model's small
asynchronous refresh method performs the bounded probe on a background thread;
AppLogic then queues its existing throttled settings reload only when actual
provider/distro evidence changed. A 30-second single-flight cache prevents
recursive reload/probe loops. No WSL wait occurs on the settings dispatcher path.

Do not treat WSL like eager Windows ACP providers. A stopped non-default WSL
source is ineligible for automatic chat/history ACP startup. An already-running
distribution is eligible; an explicitly chosen default agent-pane source or
explicit use is also eligible to start its selected distribution. Settings
enumeration alone is not use. Reuse an existing running-state query and put the
eligibility decision before any distro command, preparation, ACP process, or
session-history probe that could start the VM. Never call `wsl --shutdown` or
terminate a distribution to test this policy in the shared environment.

The tab-creation path is deliberately more conservative: automatically prewarm
a WSL helper only for the explicitly configured global WSL source. Other WSL
sources start on explicit pane open/resume, even if currently running. This
avoids adding per-tab WSL queries or trusting a stale running snapshot. Windows
prewarm is unchanged. The helper also refuses a stashed WSL startup without the
explicit authorization flag before any home/preflight/ACP command.

Persisted stashed non-default WSL conversations remain deferred layout data on
their owning tab, not a fake pane or helper. Preserve their session/source/view,
cwd and geometry during subsequent saves; explicit open materializes that same
record. Session persistence disabled omits the record. A changed effective
backend invalidates the old deferred owner; a native-model hot update does not.

Running-state checks and distro execution cannot be atomic through the public
WSL CLI. Discovery/history recheck immediately before opportunistic execution
and fail closed on query errors; a concurrent external shutdown remains a
documented cross-process race rather than an invented atomic guarantee.

## Source-specific models

Extend `probe-models` with optional `--wsl-distro`. Keep the old host default.
Reuse existing source-aware preparation/startup/cleanup, passing a Linux cwd to
WSL `new_session`. Retry accounting must include source.

Use the existing model cache with a qualified key for WSL and its historical
bare-provider key for Windows. Capture the full key and probe generation before
background work. A result for Ubuntu must not populate Windows or Debian, and
an old probe must not overwrite a later selection. WSL native models must not
be replaced by host BYOK entries; host BYOK state remains saved for switching
back to Windows.

## Existing WSL installation behavior

The user clarified: preserve installation assistance that already exists for WSL,
but do not introduce new WSL installers or bootstrap flows. Existing Claude/Codex
ACP command construction uses `npx -y` adapters for both execution sources, so
an explicit existing launch can already obtain its adapter. Discovery and
profile generation never install anything. Preserve existing source-aware
preparation behavior, subject to the stopped-distribution gate, rather than
silently converting previously supported launches to installed-only behavior.
Antigravity already has managed Linux ACP preparation; this change reuses that
existing lifecycle and introduces no new provider installer.

## Deliberate non-goals

No new MVVM framework, discovery daemon, transport, dependency, generic plugin
layer, WSL hook installer, cross-profile native-agent customization, automatic
credential copying, or broad refactoring. Extend current seams and test the
decisions and observable effects.

## Delivery

Build the owned worktree's exact Windows-target WTA and native dependency graph.
Use temporary uncommitted package/window/COM identity substitutions per
`doc\dev-worktree-package.md`; extract the resulting package to an immutable
private layout and register that exact manifest. Preserve regular Dev/Store
settings and production-installed hooks. Record package identity, binary hashes,
actual interaction proof, review snapshot/dispositions, and limitations.
