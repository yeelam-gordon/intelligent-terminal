// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.
//
// ShellIntegrationSweep.h
//
// Shared profile snapshot + install/uninstall sweep used by all three
// shell-integration entry points:
//   • FreOverlay::Save           — FRE wizard "Install" button
//   • TerminalPage::_InitShellIntegration — Settings UI "Install" button
//   • TerminalPage::_ReconcileShellIntegration — startup + settings reload
//
// All three need the same two-phase pattern:
//
//   1. Snapshot the live `_settings.AllProfiles()` ON THE UI THREAD
//      (the observable vector races with settings reload) into a cheap
//      ShellPresence bitset (pwsh / WinPS / Git Bash).
//
//   2. Run the install OR uninstall sweep on a background thread,
//      using ONLY the snapshot — never re-touch settings.AllProfiles()
//      from background code.
//
// Install AND uninstall are BOTH profile-gated: we only touch shells
// the user has a profile for. Symmetry rationale: if a user toggles
// auto-detection off, they expect cleanup for the shells they actually
// use. A stale block for a shell the user never had a profile for would
// stay (already true — we never wrote it), and the cost of touching
// every shell on every off-toggle is asymmetric (writes a `.bak.*`
// even when there's nothing to uninstall).
//
// CAVEAT: if the user installs for shell X, deletes the X profile,
// then toggles off — the X block in their HOME survives. This matches
// the install-time policy (profile presence is the gate), and the
// next reconcile after re-adding the X profile will sweep it.
//
// GH#613 — NONE of these three entry points touch WSL. RunInstall and
// RunUninstall handle PowerShell, Windows PowerShell and native Bash only;
// there is no WSL install, uninstall, probe or file I/O anywhere in this
// header beyond the claim bookkeeping below.
//
// Reaching a WSL distro's ~/.bashrc means spawning `wsl.exe -d <distro>`,
// which cold-starts that distro's VM. Sweeping every WSL profile — at silent
// app startup, on a settings reload, or when the user clicks "Install" in the
// FRE / Settings UI — would boot every installed distro merely because a
// profile exists for it. So ALL WSL reconciliation is owned by a fourth,
// lazy entry point:
//
//   • TerminalPage::_ReconcileWslProfileForNewTab — fires only when a WSL
//     Bash PROFILE is launched in a NEW TAB (never for an ordinary split or
//     a pane moved between tabs). The user is starting that distro anyway,
//     so reconciling it costs nothing extra. It runs at most ONCE per
//     PROFILE per app process — keyed on the profile's stable GUID — via the
//     claim gate below; later tabs and settings toggles do no WSL work.

#pragma once

#include <string>

#include "../inc/ShellIntegration.h"
#include "../inc/ShellIntegrationProfileGate.h"
#include "../../types/inc/utils.hpp"
#include "AgentPaneLog.h"

#include <winrt/Microsoft.Terminal.Settings.Model.h>

namespace winrt::TerminalApp::implementation::ShellIntegrationSweep
{
    namespace SI = ::Microsoft::Terminal::ShellIntegration;
    using CascadiaSettings = ::winrt::Microsoft::Terminal::Settings::Model::CascadiaSettings;
    using NewTerminalArgs = ::winrt::Microsoft::Terminal::Settings::Model::NewTerminalArgs;
    using Profile = ::winrt::Microsoft::Terminal::Settings::Model::Profile;

    // Bitset of "user has at least one profile for this shell".
    // WSL is NOT included — it has its own per-distro snapshot below.
    struct ShellPresence
    {
        bool pwsh{ false };
        bool windowsPowerShell{ false };
        bool bash{ false };
    };

    // The stable identity a WSL profile is reconciled under (GH#613). The
    // gate's unit is the PROFILE, so the key is the profile's GUID: two
    // profiles pointing at the same distro each reconcile once, and one
    // profile launched with different appended commands still reconciles
    // only once.
    inline std::wstring WslProfileKey(const Profile& profile)
    {
        return profile ? ::Microsoft::Console::Utils::GuidToString(profile.Guid()) : std::wstring{};
    }

    // WinRT adapter over the pure SI::QualifyingWslLaunchCommandline policy
    // (unit-tested in ShellIntegrationTests.cpp): the commandline to reconcile
    // when this new tab really is a launch of the configured WSL profile, else
    // empty (GH#613). All the rules — and the reasons for them — live on the
    // pure function; this only unpacks the WinRT types.
    //
    // `newTerminalArgs` may be null (e.g. duplicating a tab, which re-launches
    // the source tab's profile verbatim via CreateWithProfile — no override).
    inline std::wstring QualifyingWslLaunchCommandline(const Profile& profile,
                                                       const NewTerminalArgs& newTerminalArgs)
    {
        if (!profile)
        {
            return {};
        }
        const auto profileCommandline = profile.Commandline();
        const auto overrideCommandline = newTerminalArgs ? newTerminalArgs.Commandline() : winrt::hstring{};

        return std::wstring{ SI::QualifyingWslLaunchCommandline(std::wstring_view{ profileCommandline },
                                                                std::wstring_view{ overrideCommandline },
                                                                newTerminalArgs && newTerminalArgs.AppendCommandLine(),
                                                                newTerminalArgs && newTerminalArgs.ContentId() != 0) };
    }

    // Snapshot which non-WSL shells the user has a profile for. MUST be
    // called on the UI thread — settings.AllProfiles() is an observable
    // vector and iterating concurrently with a reload is unsafe.
    inline ShellPresence SnapshotShellPresence(const CascadiaSettings& settings)
    {
        ShellPresence out{};
        if (!settings)
        {
            return out;
        }
        for (const auto& profile : settings.AllProfiles())
        {
            const auto src = profile.Source();
            const auto cmd = profile.Commandline();
            const std::wstring_view srcSv{ src };
            const std::wstring_view cmdSv{ cmd };
            if (!out.pwsh && SI::ProfileMatchesShell(SI::Target::Pwsh, srcSv, cmdSv))
            {
                out.pwsh = true;
            }
            if (!out.windowsPowerShell && SI::ProfileMatchesShell(SI::Target::WindowsPowerShell, srcSv, cmdSv))
            {
                out.windowsPowerShell = true;
            }
            if (!out.bash && SI::ProfileMatchesShell(SI::Target::Bash, srcSv, cmdSv))
            {
                out.bash = true;
            }
            if (out.pwsh && out.windowsPowerShell && out.bash)
            {
                break;
            }
        }
        return out;
    }

    // ═══════════════════════════════════════════════════════════════════
    // GH#613 — the process-wide "already reconciled this profile" gate.
    //
    // Claimed from TerminalPage::_ReconcileWslProfileForNewTab, on the
    // TerminalApp new-tab lifecycle, when (and only when) a WSL profile is
    // launched in a NEW TAB — never for an ordinary split/pane, and never
    // from the silent startup/settings sweep. The gate is a function-local
    // static, not a TerminalPage member, so "once per profile" means once
    // for the whole app rather than once per window.
    // ═══════════════════════════════════════════════════════════════════

    inline SI::Wsl::NewTabReconcileGate& WslNewTabReconcileGate()
    {
        static SI::Wsl::NewTabReconcileGate gate;
        return gate;
    }

    // True the first time this app process sees `profileKey`, false forever
    // after. On true the caller owns the one scheduled reconcile for that
    // profile; it gives the claim back with ReleaseWslNewTabReconcile only if
    // that work never actually ran, and confirms it with
    // MarkWslNewTabReconcileHandled once the reconcile attempt has run.
    inline bool TryClaimWslNewTabReconcile(const std::wstring& profileKey)
    {
        return WslNewTabReconcileGate().TryClaim(profileKey);
    }

    inline void ReleaseWslNewTabReconcile(const std::wstring& profileKey)
    {
        WslNewTabReconcileGate().Release(profileKey);
    }

    inline void MarkWslNewTabReconcileHandled(const std::wstring& profileKey)
    {
        WslNewTabReconcileGate().MarkHandled(profileKey);
    }

    // Result aggregate for the install sweep, surfaced to the FRE /
    // Settings UI for the all-installed / any-failure verdict. A Bash
    // failure intentionally doesn't tank the verdict (a user without Git
    // Bash shouldn't see a false-alarm).
    struct InstallSweepResults
    {
        SI::InstallResult pwsh{ true, true, {}, false };       // skipped → already-installed
        SI::InstallResult windowsPowerShell{ true, true, {}, false };
        SI::InstallResult bash{ true, true, {}, false };
    };

    // Run the install sweep using the provided snapshot. Touches only
    // shells the user has a profile for. WSL is absent by design (GH#613,
    // see the file header) — symmetric with RunUninstall.
    // Synchronous — call from a background thread.
    inline InstallSweepResults RunInstall(const ShellPresence& shellPresence)
    {
        InstallSweepResults r{};
        // PowerShell hosts: the $PROFILE WRITE is profile-gated, but the
        // execution-policy VERDICT is unconditional — a Restricted / AllSigned
        // policy must stop FRE / Save even when the user has no Windows
        // Terminal profile for that host, because the shell-integration .ps1
        // can never run. ExecutionPolicyBlocksShellIntegration() is re-queried
        // here on every call (never cached), so fixing the policy offline and
        // clicking Save again on the same FRE re-evaluates cleanly.
        // See SI::ResolvePowerShellHostInstall for the rationale / regression
        // guard.
        //
        // The write lambda calls the path-taking install (DiscoverProfilePath +
        // Install) directly rather than InstallForTarget, which would re-query
        // the execution policy a second time — ResolvePowerShellHostInstall has
        // already verified it for this host, so the extra probe is a redundant
        // PowerShell spawn (pure FRE / Save latency).
        const auto installSkippingPolicyProbe = [](SI::Target target) -> SI::InstallResult {
            auto profilePath = SI::DiscoverProfilePath(target);
            if (profilePath.empty())
            {
                return { false, false, L"Could not discover PowerShell profile path" };
            }
            return SI::Install(profilePath);
        };
        // Probe each PowerShell host's execution policy, and log the raw outcome
        // (policy + whether the probe timed out + verdict) so a future FRE
        // false-block is diagnosable straight from terminal-agent-pane.log. The
        // probe itself is a pure query (ExecutionPolicyBlocksShellIntegration does
        // no I/O); the logging lives here, at the app layer, next to the existing
        // [FRE] shell-integration logging — not buried in the shared inc/ header.
        const auto probeExecutionPolicyBlocked = [](SI::Target t, const char* label) {
            std::wstring policy;
            bool timedOut = false;
            const bool blocked = SI::ExecutionPolicyBlocksShellIntegration(t, &policy, &timedOut);
            _agentPaneLog(std::string{ "[FRE] EP probe " } + label +
                          " policy='" + winrt::to_string(winrt::hstring{ policy }) + "'" +
                          " timedOut=" + (timedOut ? "1" : "0") +
                          " -> " + (blocked ? "BLOCKED" : "not-blocked"));
            return blocked;
        };
        r.pwsh = SI::ResolvePowerShellHostInstall(
            shellPresence.pwsh,
            probeExecutionPolicyBlocked(SI::Target::Pwsh, "pwsh"),
            [&] { return installSkippingPolicyProbe(SI::Target::Pwsh); });
        r.windowsPowerShell = SI::ResolvePowerShellHostInstall(
            shellPresence.windowsPowerShell,
            probeExecutionPolicyBlocked(SI::Target::WindowsPowerShell, "winPs"),
            [&] { return installSkippingPolicyProbe(SI::Target::WindowsPowerShell); });
        if (shellPresence.bash)
        {
            r.bash = SI::InstallForTarget(SI::Target::Bash);
        }
        return r;
    }

    // Run the uninstall sweep using the provided snapshot. Mirrors
    // RunInstall: profile-gated symmetric cleanup. A shell with no
    // profile is left untouched (we never installed for it either).
    //
    // Synchronous — call from a background thread.
    inline void RunUninstall(const ShellPresence& shellPresence)
    {
        if (shellPresence.pwsh)
        {
            (void)SI::UninstallForTarget(SI::Target::Pwsh);
        }
        if (shellPresence.windowsPowerShell)
        {
            (void)SI::UninstallForTarget(SI::Target::WindowsPowerShell);
        }
        if (shellPresence.bash)
        {
            (void)SI::UninstallForTarget(SI::Target::Bash);
        }
    }
}
