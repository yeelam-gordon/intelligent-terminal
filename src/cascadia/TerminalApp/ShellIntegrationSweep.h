// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.
//
// ShellIntegrationSweep.h
//
// Shared profile snapshot + install/uninstall sweep used by the
// shell-integration entry points:
//   • FreOverlay::Save           — FRE wizard "Install" button
//   • TerminalPage::_InitShellIntegration — Settings UI "Install" button
//   • TerminalPage::_ReconcileShellIntegration — startup + settings reload
//   • EnsureWslInstalledAsync    — lazy new-tab WSL install
//
// The sweep callers need the same two-phase pattern:
//
//   1. Snapshot the live `_settings.AllProfiles()` ON THE UI THREAD
//      (the observable vector races with settings reload). The
//      snapshot is two cheap copies:
//        - WSL distro names (deduped, malformed entries dropped)
//        - non-WSL ShellPresence bitset (pwsh / WinPS / Git Bash)
//
//   2. Run the install OR uninstall sweep on a background thread,
//      using ONLY the snapshot — never re-touch settings.AllProfiles()
//      from background code.
//
// Install AND uninstall are BOTH profile-gated: we only touch shells
// the user has a profile for, and only WSL distros the user has a WT
// profile for. Symmetry rationale: if a user toggles auto-detection
// off, they expect cleanup for the shells they actually use. A
// stale block for a shell the user never had a profile for would
// stay (already true — we never wrote it), and the cost of touching
// every shell on every off-toggle is asymmetric (writes a `.bak.*`
// even when there's nothing to uninstall).
//
// CAVEAT: if the user installs for shell X, deletes the X profile,
// then toggles off — the X block in their HOME survives. This matches
// the install-time policy (profile presence is the gate), and the
// next reconcile after re-adding the X profile will sweep it.
//
// GH#613: startup omits WSL only from the shared INSTALL path by selecting a
// native-shell target set. Explicit one-time setup (FRE / Settings "Install")
// keeps the baseline WSL sweep, and the new-tab path independently ensures
// the actually launched WSL profile once per app process.

#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "../inc/ShellIntegration.h"
#include "../inc/ShellIntegrationProfileGate.h"
#include "../../types/inc/utils.hpp"
#include "AgentPaneLog.h"

#include <winrt/Microsoft.Terminal.Settings.Model.h>
#include <wil/resource.h>

namespace winrt::TerminalApp::implementation::ShellIntegrationSweep
{
    namespace SI = ::Microsoft::Terminal::ShellIntegration;
    using CascadiaSettings = ::winrt::Microsoft::Terminal::Settings::Model::CascadiaSettings;
    using Profile = ::winrt::Microsoft::Terminal::Settings::Model::Profile;

    // Bitset of "user has at least one profile for this shell".
    // WSL is NOT included — it has its own per-distro snapshot below.
    struct ShellPresence
    {
        bool pwsh{ false };
        bool windowsPowerShell{ false };
        bool bash{ false };
    };

    enum class InstallTargets : uint8_t
    {
        None = 0x00,
        Pwsh = 0x01,
        WindowsPowerShell = 0x02,
        Bash = 0x04,
        Wsl = 0x08,
        WindowsShells = 0x07, // Pwsh | WindowsPowerShell | Bash (Git Bash)
        All = 0xFF,
    };

    constexpr InstallTargets operator|(InstallTargets lhs, InstallTargets rhs) noexcept
    {
        return static_cast<InstallTargets>(static_cast<uint8_t>(lhs) | static_cast<uint8_t>(rhs));
    }

    constexpr bool HasInstallTarget(InstallTargets set, InstallTargets flag) noexcept
    {
        return (static_cast<uint8_t>(set) & static_cast<uint8_t>(flag)) == static_cast<uint8_t>(flag);
    }

    static_assert(HasInstallTarget(InstallTargets::Pwsh, InstallTargets::Pwsh));
    static_assert(HasInstallTarget(InstallTargets::Pwsh | InstallTargets::Bash, InstallTargets::Bash));
    static_assert(!HasInstallTarget(InstallTargets::None, InstallTargets::Pwsh));
    static_assert(!HasInstallTarget(InstallTargets::WindowsShells, InstallTargets::Wsl));
    static_assert(HasInstallTarget(InstallTargets::All, static_cast<InstallTargets>(0x10)));
    static_assert(!HasInstallTarget(InstallTargets::WindowsShells, static_cast<InstallTargets>(0x10)));

    // Return the profile's launch commandline IF it is a WSL profile
    // (else empty). Uses the pure SI::IsWslProfile predicate (unit-tested in
    // ShellIntegrationTests.cpp): a WSL profile is one whose launch leaf is
    // `wsl(.exe)`, or which launches the legacy System32 `bash.exe` (the WSL
    // default-distro launcher). Recognition is purely commandline-based — no
    // Source needed — so a hand-made / sourceless `wsl -d <distro>` profile is
    // covered too.
    //
    // We return the COMMANDLINE, not a parsed distro name: the installer
    // runs this exact commandline with a probe appended and reads the
    // distro's own `$WSL_DISTRO_NAME` / `$HOME`. So `--distribution-id
    // {GUID}`, `-d <name>`, sourceless custom, default-distro and renamed
    // profiles all work uniformly with no parsing.
    inline std::wstring WslProfileCommandline(const Profile& profile)
    {
        // Check the predicate on a view first; only copy into std::wstring for
        // the (few) profiles that are actually WSL — this snapshot runs on the
        // UI thread for every profile.
        const auto cmd = profile.Commandline();
        if (cmd.empty() || !SI::IsWslProfile(std::wstring_view{ cmd }))
        {
            return {};
        }
        return std::wstring{ cmd };
    }

    // Snapshot the user's distinct WSL profile commandlines. MUST be called
    // on the UI thread — settings.AllProfiles() is an observable vector and
    // iterating concurrently with a reload is unsafe. Deduped by commandline
    // (two profiles launching the identical command touch the distro once;
    // two profiles for the SAME distro via different commands are probed
    // separately but converge on the same \\wsl$ path, which the installer
    // handles idempotently).
    inline std::vector<std::wstring> SnapshotWslCommandlines(const CascadiaSettings& settings)
    {
        std::vector<std::wstring> out;
        if (!settings)
        {
            return out;
        }
        std::set<std::wstring> seen;
        for (const auto& profile : settings.AllProfiles())
        {
            auto cmd = WslProfileCommandline(profile);
            if (cmd.empty())
            {
                continue;
            }
            if (seen.insert(cmd).second)
            {
                out.emplace_back(std::move(cmd));
            }
        }
        return out;
    }

    // Snapshot which non-WSL shells the user has a profile for. Same
    // UI-thread restriction as SnapshotWslCommandlines.
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

    // Result aggregate for the install sweep, surfaced to the FRE /
    // Settings UI for the all-installed / any-failure verdict. WSL +
    // Bash failures intentionally don't tank the verdict (a user
    // without Git Bash / running WSL shouldn't see a false-alarm).
    struct InstallSweepResults
    {
        SI::InstallResult pwsh{ true, true, {}, false };       // skipped → already-installed
        SI::InstallResult windowsPowerShell{ true, true, {}, false };
        SI::InstallResult bash{ true, true, {}, false };
        std::vector<std::pair<std::wstring, SI::InstallResult>> wsl;
    };

    // Run the install sweep using the provided snapshot. Touches only
    // shells the user has a profile for; touches each WSL distro once.
    // Synchronous — call from a background thread.
    inline InstallSweepResults RunInstall(const ShellPresence& shellPresence,
                                          const std::vector<std::wstring>& wslCommandlines,
                                          InstallTargets targets = InstallTargets::All)
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
        if (HasInstallTarget(targets, InstallTargets::Pwsh))
        {
            r.pwsh = SI::ResolvePowerShellHostInstall(
                shellPresence.pwsh,
                probeExecutionPolicyBlocked(SI::Target::Pwsh, "pwsh"),
                [&] { return installSkippingPolicyProbe(SI::Target::Pwsh); });
        }
        if (HasInstallTarget(targets, InstallTargets::WindowsPowerShell))
        {
            r.windowsPowerShell = SI::ResolvePowerShellHostInstall(
                shellPresence.windowsPowerShell,
                probeExecutionPolicyBlocked(SI::Target::WindowsPowerShell, "winPs"),
                [&] { return installSkippingPolicyProbe(SI::Target::WindowsPowerShell); });
        }
        if (HasInstallTarget(targets, InstallTargets::Bash) && shellPresence.bash)
        {
            r.bash = SI::InstallForTarget(SI::Target::Bash);
        }
        if (HasInstallTarget(targets, InstallTargets::Wsl))
        {
            r.wsl.reserve(wslCommandlines.size());
            for (const auto& cmd : wslCommandlines)
            {
                const auto res = SI::InstallWslBash(cmd);
                auto name = SI::Wsl::ProbedDistroName(cmd);
                r.wsl.emplace_back(name.empty() ? cmd : std::move(name), res);
            }
        }
        return r;
    }

    // Run the uninstall sweep using the provided snapshot. Mirrors
    // RunInstall: profile-gated symmetric cleanup. A shell with no
    // profile is left untouched (we never installed for it either).
    // Synchronous — call from a background thread.
    inline void RunUninstall(const ShellPresence& shellPresence,
                             const std::vector<std::wstring>& wslCommandlines)
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
        for (const auto& cmd : wslCommandlines)
        {
            (void)SI::UninstallWslBash(cmd);
        }
    }

    // Claim one launched WSL profile, then serialize its actual install attempt
    // against the page's reconcile mutex. If settings were disabled before the
    // background work starts, release the claim so a later qualifying launch can
    // retry.
    // The enabled callback must retain the owner of reconcileMutex for the
    // whole coroutine. Profile properties are read before the background switch.
    inline safe_void_coroutine EnsureWslInstalledAsync(Profile profile,
                                                       winrt::hstring actualCommandline,
                                                       std::function<bool()> isEnabled,
                                                       std::mutex& reconcileMutex)
    {
        if (!profile || !isEnabled || !isEnabled())
        {
            co_return;
        }
        const auto profileCommandline = profile.Commandline();
        const std::wstring commandline{ SI::Wsl::QualifyingProfileLaunchCommandline(
            std::wstring_view{ profileCommandline }, std::wstring_view{ actualCommandline }) };
        if (commandline.empty())
        {
            co_return;
        }

        const auto profileKey = ::Microsoft::Console::Utils::GuidToString(profile.Guid());
        static SI::Wsl::NewTabReconcileGate gate;
        if (!gate.TryClaim(profileKey))
        {
            co_return;
        }
        auto releaseClaim = wil::scope_exit([&]() noexcept {
            gate.Release(profileKey);
        });

        const auto logIdentity = "profile='" + winrt::to_string(profile.Name()) +
                                 "' guid='" + winrt::to_string(winrt::hstring{ profileKey }) + "'";
        _agentPaneLog("[ShellIntegration] WSL new-tab reconcile claimed " + logIdentity +
                      " commandline='" + winrt::to_string(winrt::hstring{ commandline }) + "'");

        co_await winrt::resume_background();

        SI::InstallResult result{};
        {
            std::lock_guard<std::mutex> guard{ reconcileMutex };
            if (!isEnabled())
            {
                _agentPaneLog("[ShellIntegration] WSL new-tab install skipped after disable for " + logIdentity);
                co_return;
            }

            gate.MarkHandled(profileKey);
            result = RunInstall(ShellPresence{}, { commandline }, InstallTargets::Wsl).wsl.front().second;
        }

        const auto outcome = result.success ? (result.alreadyInstalled ? "no-change" : "done") : "FAILED";
        _agentPaneLog("[ShellIntegration] WSL new-tab install " + std::string{ outcome } +
                      " for " + logIdentity +
                      (result.errorMessage.empty() ? std::string{} : " error=" + winrt::to_string(winrt::hstring{ result.errorMessage })));
    }

}
