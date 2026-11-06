# Resume sessions with their agent profile

**Design proposal only.** No application behavior changes in this PR.
Review the annotated mockup and the layer table; implementation follows separately.

Today, editing an agent profile does not reliably affect how a historical session
reopens. Generated agent profiles can also be deleted, and agents added in
AI Agents settings do not receive corresponding profiles.

![Proposed agent profile editor, custom-agent setup, and agent-pane profile with numbered annotations](images/agent-profile-resume.svg)

## Proposed UI and behavior

| Annotation | Change |
| --- | --- |
| 1 | Show the provider and a **Managed profile** badge. Keep identity independent of the editable display name. |
| 2 | Add **Resume arguments** below additional startup arguments. Built-ins inherit a provider-specific default; edits have the existing setting reset/inheritance affordances. An empty override explicitly disables native resume. |
| 3 | Show a read-only **Resume command preview** with a sample session ID, built by the same code used to launch. This is not a session ID saved in the profile. |
| 4 | Replace Delete with **This profile is managed by AI Agents. You can hide it instead.** Keep appearance, hide, and copy controls. Protect the managed original, not user-created copies. |
| 5 | Each custom agent saved in AI Agents gets one corresponding managed profile. Link to it from the custom-agent editor. Native launch and resume commands must be explicitly configured; an ACP command is not assumed to be an interactive CLI command. |
| 6 | Protect the existing **Agent Pane** profile too. Show **Session restore: Managed by the agent pane (ACP)** instead of native resume arguments. Do not expose helper pipes, window IDs, or native startup flags here. |

These are additions to the current profile page, not a replacement settings UI.
The mockup abbreviates unchanged controls. "Resume" means reopen a particular
conversation; it does not mean always resume the latest session on ordinary
new-tab launch, splitting, or when Sessions is off.

## Launch contract

Proposed inheritable profile key: `agentProfile.resumeArguments`.
Use an argument template, not a second executable or shell script:

```jsonc
{
    "agentProfile.id": "claude",
    "agentProfile.model": "",
    "agentProfile.arguments": "--add-dir \"C:\\shared project\"",
    "agentProfile.resumeArguments": "--resume {sessionId}"
}
```

An omitted value inherits the provider default. An explicit empty string means
native resume is unavailable. A nonempty template must contain exactly one
standalone `{sessionId}` argument; reject missing, repeated, embedded, or unknown
placeholders with an inline error and a launch-time error. Parse the template
before replacing that token with the validated, opaque session ID. Quote it as
one argument through the existing executable/batch/WSL launch helpers; never
evaluate it as script text or substitute it into an already quoted command.

| Built-in provider | Default resume arguments (current repository contract) |
| --- | --- |
| GitHub Copilot | `--resume {sessionId}` |
| Claude | `--resume {sessionId}` |
| Codex | `resume {sessionId}` |
| Gemini | `--resume {sessionId}` |
| OpenCode | `--session {sessionId}` |
| Google Antigravity | `--conversation {sessionId}` |
| Custom agent | Empty until configured; never guess built-in syntax |

These defaults reflect `tools/wta/src/agent_registry.rs:130-294`, not a claim that
every installed CLI version has been live-verified. Implementation must check
the supported CLI versions, including option ordering and adapter/native history
compatibility. Antigravity currently cannot resume ACP conversations via its CLI.

Terminal owns effective profile resolution and native resume command assembly.
Resolve the profile's executable again at launch; preserve its model, permission
mode, extra arguments, environment, appearance, and close-on-exit behavior.
Provider-aware assembly must place verbs such as Codex's `resume` correctly,
rather than blindly appending text to the normal launch command. Reject
conflicting resume selectors in additional arguments instead of resuming a
different conversation. Built-in defaults belong with native profile metadata;
WTA must not reconstruct an alternative default command for these profile routes.

An explicit profile `commandline` remains an override: use that base command
unchanged, do not resurrect hidden structured model/permission/extra arguments,
and use only an explicitly configured resume template. Show "Configure resume
arguments for this command" rather than silently applying a potentially
incompatible generated template. Existing explicit new-tab/action overrides keep
their precedence.

For custom agents, generate a stable profile for each canonical `custom:<id>`
across the saved ACP/delegation entries, deduplicating only identical IDs.
Add a distinct **Interactive command** field to their AI Agents editor, mapped
to the generated profile's command line; leave it unconfigured initially.
The generated profile remains editable but is not offered as launchable until
that command is set. Explain this state and link to its configuration.
Do not run an ACP server or a prompt-bearing delegation command as a native TUI.
Changing/removing a custom command must reconcile its existing command-derived
identity explicitly; do not silently attach an old profile to a different agent.

## Matching sessions and profile lifetime

Record the originating profile GUID alongside the qualified session identity
(provider, host/WSL distro, and existing session-universe identity). Resuming a
known session uses that GUID after validating provider and execution location,
not the profile name, a command-string heuristic, or the global default profile.
This keeps user-created project-profile copies distinguishable.

For imported history with no profile GUID, use the canonical generated profile
only when provider and execution location match. If it is unavailable or
incompatible, show a matching-profile chooser/configuration action; never open a
default shell or use a Windows profile for a WSL session. Keep the existing WSL
resume route for WSL history without a corresponding source-qualified profile;
this proposal does not add automatic WSL profile discovery. Switching that route
to profiles requires explicit location metadata and equivalent WSL coverage.
Unavailable stored directories retain the existing reported fallback to the
selected profile's directory.

Live sessions still focus their existing pane. ACP-origin sessions retain
capability-gated `session/load`, the selected provider/source/model, and the
protected Agent Pane profile. The native template cannot override ACP loading
or make a native-only custom agent ACP-capable. Hook availability does not gate
history listing or resume.

Protect generated originals while their built-in provider remains supported or
their custom agent remains configured. Missing executables and policy blocks
make them unavailable, not deletable or silently replaced. Removing support or
deleting the custom-agent entry releases protection on retained orphaned settings;
do not discard overrides automatically. The internal Agent Pane profile remains
protected independently. Enforce this in the delete handler as well as the UI,
and reconcile old generated-profile deletion tombstones so supported originals
return with their overrides intact. User-created copies remain deletable.

## Required implementation layers

C++ project paths below are under `src/cascadia/`; WTA source filenames are
under `tools/wta/src/` unless a full path is shown. These are future changes,
not files modified by this design PR.

| Layer / existing owner | Required change | Purpose |
| --- | --- | --- |
| Provider metadata: `src/cascadia/inc/AgentRegistry.h`, `AgentProfileUtils.h`; WTA `tools/wta/src/agent_registry.rs` | Define native resume defaults and provider-aware assembly at the Terminal profile boundary; preserve ACP capabilities and check metadata consistency. | One effective native profile launch, including verb/flag differences, without mixing ACP and native customization. |
| Settings/schema: `TerminalSettingsModel/MTSMSettings.h`, profile projection/serialization, `doc/cascadia/profiles.schema.json` | Add inheritable resume arguments, reset semantics, template validation, and explicit-command behavior. | Persist user customization without changing existing normal-launch overrides. |
| Profile generation: `TerminalSettingsModel/AgentProfileGenerator.cpp`, `CascadiaSettingsSerialization.cpp`, custom-entry reconciliation | Generate custom profiles after saved custom settings are available; retain stable GUIDs/overrides and reconcile deletion suppression. | Every configured custom agent has a corresponding profile, without conflating ACP and native commands. |
| Profile lifetime: model deletion eligibility, `TerminalSettingsEditor/ProfileViewModel.cpp:655`, `MainPage.cpp:1497`, `TerminalSettingsModel/defaults.json:44` | Compute managed-original protection centrally and enforce it on deletion; cover Agent Pane and unsupported-provider cleanup. | Prevent accidental removal of required profiles while keeping ordinary copies deletable. |
| Settings UI: `TerminalSettingsEditor/Profiles_Base.xaml`, `ProfileViewModel.*`, `AIAgents*`, resources | Add annotations 1-6, command preview, custom Interactive command/link, inline errors, and accessible localized labels. | Let users understand and configure both new-session and resume behavior without editing JSON. |
| Session identity/storage: `TerminalApp/TerminalPage.cpp`, WTA session registry/history/bindings | Carry profile GUID with existing qualified identity; retain identity across moves/restarts and tolerate older records without it. | Resume the user's actual project profile, not an arbitrary provider match. |
| Session activation: WTA `app.rs:3290-3690`, `master/mod.rs:8714-8800`, `coordinator.rs`; Terminal protocol/`wtcli` boundary | Route native resume as profile GUID + qualified session identity to Terminal; return an actual launch receipt/error. Add a dedicated operation only if existing tab creation cannot transport typed resume intent; preserve existing COM ABI. | Make both Sessions UI and sidebar activation honor the profile instead of emitting independent `-c` commands. |
| Saved layouts: `TerminalApp/TabManagement.cpp:770`, `src/cascadia/inc/AgentPaneRestore.h`, connection creation in `TerminalPage.cpp` | Persist profile/session intent and resolve it again on restore; migrate legacy saved native resume commands without changing ACP restoration. | Avoid freezing obsolete executable paths or bypassing profile settings after restart. |
| Focused coverage: settings-model unit tests, `LocalTests_TerminalApp/TabTests.cpp`, WTA routing tests, ItE2E | Cover command composition, reset/empty/override cases, custom profile lifecycle, both activation UIs, and restart/source identity. | Prove actual launch arguments and retained settings, not just preview text. |

## Implementation acceptance

Use executable fixtures to capture argv, environment, profile GUID, and cwd for
all six built-ins plus one custom agent. Cover spaces, invalid templates, batch
shims, Codex verb ordering, missing executables, policy blocks, and explicit
command overrides. Test two copies of one provider profile and older history
without a GUID. Exercise Sessions, sidebar, and saved-layout restoration.
Verify protected deletion through the UI and handler, custom removal/re-add,
old suppression state, and unsupported-provider cleanup. Preserve live focus,
ACP loading, Sessions-OFF behavior, hook-less resume, and existing WSL routing.

No runtime, deployment, hook installation, or settings migration is performed
by this proposal.
