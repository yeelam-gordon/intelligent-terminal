// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "pch.h"
#include "AgentProfileGenerator.h"
#include "GlobalAppSettings.h"
#include "DynamicProfileUtils.h"
#include "../inc/AgentProfileUtils.h"
#include "../inc/AgentRegistry.h"
#include "../inc/CustomAgentId.h"
#include "../inc/AcpAgentPresets.h"
#include "../inc/NamedCustomAcpCommands.h"
#include <mutex>
#include <set>

using namespace winrt::Microsoft::Terminal::Settings::Model;
namespace AgentProfiles = ::Microsoft::Terminal::AgentProfiles;

AgentProfileGenerator::AgentProfileGenerator(const implementation::GlobalAppSettings* settings)
{
    if (settings)
    {
        namespace Named = ::Microsoft::Terminal::Settings::Model::NamedCustomAcpCommands;
        const auto appendLegacy = [&](const winrt::hstring& command) {
            const auto id = L"custom:" + std::wstring{ ::Microsoft::Terminal::Settings::Model::DeriveCustomAgentId(command) };
            if (!command.empty() && id != L"custom:")
            {
                _customAgentIds.emplace_back(id);
            }
        };
        for (const auto& commands : { settings->AcpCustomCommands(), settings->DelegateCustomCommands() })
        {
            for (const auto& command : commands)
            {
                appendLegacy(command);
            }
        }
        const auto named = settings->AcpNamedCustomCommands();
        if (!Named::HasSelectedBinding(settings->AcpAgent(), named))
        {
            appendLegacy(settings->AcpCustomCommand());
        }
        appendLegacy(settings->DelegateCustomCommand());
        for (const auto& entry : named)
        {
            if (Named::IsValidId(entry.Key()) && Named::IsValidCommand(entry.Value()))
            {
                _customAgentIds.emplace_back(entry.Key());
            }
        }
    }
}

std::wstring_view AgentProfileGenerator::GetNamespace() const noexcept
{
    return AgentProfiles::Source;
}

std::wstring_view AgentProfileGenerator::GetDisplayName() const noexcept
{
    return RS_(L"AgentProfileGeneratorDisplayName");
}

std::wstring_view AgentProfileGenerator::GetIcon() const noexcept
{
    return L"\uE99A";
}

const AgentProfileGenerator::DiscoveryCache::Snapshot& AgentProfileGenerator::DiscoveryCache::Get(
    const std::chrono::steady_clock::time_point now,
    const std::function<Snapshot()>& probe)
{
    if (!_snapshot || now - _lastProbe >= std::chrono::seconds{ 30 })
    {
        try
        {
            _snapshot = probe();
            _lastProbe = now;
        }
        catch (...)
        {
            LOG_CAUGHT_EXCEPTION_MSG("Native agent profile discovery failed; retaining the last successful snapshot");
            if (!_snapshot)
            {
                throw;
            }
        }
    }
    return *_snapshot;
}

void AgentProfileGenerator::GenerateProfiles(std::vector<winrt::com_ptr<implementation::Profile>>& profiles) const
{
    static std::mutex mutex;
    static DiscoveryCache cache;
    std::scoped_lock lock{ mutex };
    const auto& snapshot = cache.Get(std::chrono::steady_clock::now(), [] {
        return AgentProfiles::Discover(AgentProfiles::NativePath());
    });
    namespace Registry = ::Microsoft::Terminal::Settings::Model::AgentRegistry;
    for (const auto& agent : Registry::BuiltinNativeProfileAgents)
    {
        const auto found = snapshot.find(std::wstring{ agent.id });
        if (found == snapshot.end() || !::Microsoft::Terminal::Settings::Model::AgentPolicy::IsAgentAllowed(agent.id))
        {
            continue;
        }
        auto profile = CreateDynamicProfile(AgentProfiles::GeneratedIdentity(agent.id));
        profile->Name(winrt::hstring{ agent.displayName });
        profile->Icon(winrt::hstring{ L"ms-appx:///AgentIcons/" + std::wstring{ agent.id } + L".svg" });
        profile->AgentProfileId(winrt::hstring{ agent.id });
        profile->StartingDirectory(L"%USERPROFILE%");
        // Generation defaults only. Runtime resume always reads the effective profile.
        const auto resume = agent.id == L"opencode"    ? L"--session" :
                            agent.id == L"codex"       ? L"resume" :
                            agent.id == L"antigravity" ? L"--conversation" :
                                                         L"--resume";
        profile->AgentProfileResumeArguments(resume);
        profile->Commandline(winrt::hstring{ AgentProfiles::BuildCommand(found->second.native(), agent.id, {}, {}, {}) });
        profiles.emplace_back(std::move(profile));
    }
    if (::Microsoft::Terminal::Settings::Model::AgentPolicy::IsCustomAgentAllowed())
    {
        std::set<std::wstring> seen;
        for (const auto& id : _customAgentIds)
        {
            if (!seen.insert(id).second)
            {
                continue;
            }
            auto profile = CreateDynamicProfile(AgentProfiles::GeneratedIdentity(id));
            profile->Name(winrt::hstring{ id.substr(7) });
            profile->AgentProfileId(winrt::hstring{ id });
            if (const auto preset = ::Microsoft::Terminal::Settings::Model::AcpAgentPresets::FindByCustomId(id))
            {
                profile->Name(winrt::hstring{ preset->name });
                profile->Icon(winrt::hstring{ ::Microsoft::Terminal::Settings::Model::AcpAgentPresets::IconPath(*preset) });
            }
            profile->StartingDirectory(L"%USERPROFILE%");
            // An ACP command may name an adapter, not an interactive CLI.
            // Require a separately configured native command; never guess one.
            profile->Commandline(L"");
            profiles.emplace_back(std::move(profile));
        }
    }
}
