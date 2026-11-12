# WSL agents independently of terminal profiles

Base: `microsoft/intelligent-terminal`, `main`,
`ed841e9ce117fc3b73c33701172933abcdd28854`.
Worktree: `Q:\official\intelligent-terminal-worktrees\wsl-agent-selection`.
Branch: `dev/yeelam/wsl-agent-selection`.

## Requirement and acceptance

A user working in PowerShell or Command Prompt must be able to choose an
installed WSL agent directly in global Agent settings, without changing their
terminal profile. The global default must also work in WSL profiles. A profile
can override that default with an exact Windows or distribution-specific agent.
Agent pane and command-palette delegation are separate selections. Also generate
native agent profiles for discovered WSL agents.

The user's additional performance requirement is authoritative: do not start a
stopped distribution merely to discover agents, populate Settings, generate
profiles, list sessions, or prewarm unused ACP processes. WSL ACP can start when
that distribution is already running, it is the explicitly configured default
agent-pane source, or the user explicitly uses that source. This includes
session-list ACP processes, not only chat.

Deliver source-backed investigation, a minimal MVVM design, a reasonable
unit-test inventory, implementation, an isolated worktree Dev deployment, and
a fork Copilot review loop with independently assessed feedback. Preserve the
regular installation, settings, sessions, hooks, and unrelated worktrees.

## Findings in the baseline

| Boundary | Evidence | Actual gap |
| --- | --- | --- |
| Global picker | `src\cascadia\TerminalSettingsEditor\AIAgentsViewModel.cpp:527-615` | Builds bare provider entries from Windows availability only. There is no distribution discovery or execution-source selection. |
| Profile picker | `src\cascadia\TerminalSettingsEditor\ProfileViewModel.cpp:85-166,398-475` | Already has qualified `host:<agent>` and `wsl:<distro>:<agent>` entries, but only probes a distribution when the profile command is recognized as WSL. A Windows profile explicitly clears WSL candidates. |
| Persisted identity | `src\cascadia\TerminalSettingsModel\MTSMSettings.h:81-90`; `src\cascadia\inc\AgentPaneBackend.h:13-83` | Global settings store the provider but not its source. Profiles store both. Changing labels alone cannot fix runtime selection. |
| Global launch | `src\cascadia\TerminalApp\TerminalPage.cpp:1807-1851,4451-4471` | Global command generation and helper arguments explicitly default to Windows. |
| Profile launch restriction | `src\cascadia\TerminalApp\TerminalPage.cpp:2884-2916,4401-4437` | A WSL backend is rejected when the pane's reported shell differs from the selected distribution. This intentionally old guard also excludes PowerShell/cmd and a different WSL distro. |
| Settings reload | `src\cascadia\TerminalApp\TerminalPage.cpp:2537-2650,2850-2990` | Reconciliation tracks provider/model/profile backends, but no global execution source. A source change for the same provider would otherwise be missed. |
| Delegation | `src\cascadia\TerminalApp\TerminalPage.cpp:2298-2350`; `tools\wta\src\cli\delegate.rs:185-220,463-537` | WTA already accepts exact host/WSL delegation. C++ supplies WSL only for a profile override; Windows cwd is not translated for explicit WSL delegation. |
| Model discovery | `src\cascadia\TerminalSettingsEditor\AIAgentsViewModel.cpp:1887-1998`; `tools\wta\src\protocol\acp\probe.rs:55-108,151-174` | Settings probes always start on the host. Model cache entries are keyed by provider, so they cannot distinguish Windows and WSL accounts/catalogs. |
| WSL execution | `tools\wta\src\agent_source.rs:22-90`; `tools\wta\src\protocol\acp\spawn.rs:584-690` | Already source-aware: the master process pool distinguishes source and launches ACP in an explicit distribution. No new transport or second orchestrator is needed. |
| Working directory | `src\cascadia\inc\AgentSourceUtils.h:211-241`; `tools\wta\src\agent_source.rs:104-188` | Helper and agent cwd are already separate. Drive paths can be translated to Linux form. Linux paths from a different distribution cannot be assumed to name the same workspace. |
| Session MCP | `tools\wta\AGENTS.md:35-58`; `tools\wta\src\master\session_mcp.rs` | A distro-local relay already reaches the master-owned endpoint. Terminal actions must continue targeting the owning helper's actual shell, not be retargeted to match the agent. |
| MVVM ownership | `src\cascadia\TerminalSettingsEditor\MainPage.cpp:1469-1495` | Settings already has asynchronous availability discovery and distributes results to profile VMs. Extend that existing owner rather than introducing a discovery service or putting process work in XAML code-behind. |

## What is not a fundamental blocker

ACP over Windows-to-WSL stdio, distribution-specific process pooling, MCP relay,
canonical provider policy checks, and source-qualified session identity already
exist. An agent's execution environment need not equal its target terminal's
environment. For example, a WSL Copilot process can request a command in an
owning PowerShell pane through the existing confirmation-gated terminal tools.
Its own shell tools still run in WSL; these are intentionally different paths.

## Constraints and failure behavior

- Never put `wsl:Ubuntu:copilot` into the canonical provider setting/policy ID.
- A selected missing distribution or failed probe must not silently switch to a
  host agent. Keep the saved choice visible as unavailable.
- No custom-provider-in-WSL editor or native CLI profile customization redesign
  is required. Existing custom command settings remain Windows-owned.
- Preserve host BYOK behavior. WSL uses its own provider environment; do not
  transfer Windows credentials or pretend a host BYOK model is a WSL catalog.
- Discover registered user distributions, not merely the current profile or
  currently running ones. Exclude utility distributions consistently with
  existing WSL profile generation. Enumeration must not start a distribution;
  executable probing is restricted to already-running distributions. Retain
  previously known/saved choices without implying they are currently available.
  Do not install agents, change hooks, or modify global registrations.
- Treat discovery failure as unknown, log it, and retain saved selections.
  Bound subprocesses and ignore stale UI publication after navigation/reload.
- Preserve explicit tab overrides, stashed panes, profile precedence, policy,
  qualified session ownership, and Windows helper working directories.
- Cross-distro POSIX paths are not portable. A launch without trustworthy cwd
  uses the selected distribution's home, not an unrelated same-looking path.

## Evidence still required

Implementation and validation results belong in `validation.md`. This document
describes inspected baseline source, not a claim that the requested behavior,
deployment, or review has already passed.
