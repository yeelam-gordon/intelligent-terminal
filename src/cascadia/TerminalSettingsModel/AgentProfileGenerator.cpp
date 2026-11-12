// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "pch.h"
#include "AgentProfileGenerator.h"
#include "DynamicProfileUtils.h"
#include "../inc/AgentProfileUtils.h"
#include "../inc/AgentRegistry.h"
#include <mutex>
#include <set>

using namespace winrt::Microsoft::Terminal::Settings::Model;
namespace AgentProfiles = ::Microsoft::Terminal::AgentProfiles;

namespace
{
    AgentProfileGenerator::WslSourceCache& WslCache()
    {
        static AgentProfileGenerator::WslSourceCache cache;
        return cache;
    }

    auto WslProfileEvidence(const AgentProfileGenerator::WslSourceCache::Snapshot& sources)
    {
        std::map<std::wstring, std::unordered_set<std::wstring>> evidence;
        for (const auto& source : sources)
        {
            if (!source.agentIds.empty())
            {
                evidence.emplace(source.distro, source.agentIds);
            }
        }
        return evidence;
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

void AgentProfileGenerator::RetainKnownWslAgents(WslDiscoveryCache::Snapshot& sources, const WslDiscoveryCache::Snapshot* previous)
{
    for (auto& source : sources)
    {
        if (!source.running || source.probeFailed)
        {
            // Stopped or failed sources cannot establish new installation evidence.
            source.agentIds.clear();
            if (previous)
            {
                const auto found = std::ranges::find(*previous, source.distro, &::Microsoft::Terminal::AgentAvailability::AgentSourceSnapshot::distro);
                if (found != previous->end())
                {
                    source.agentIds = found->agentIds;
                }
            }
        }
    }
}

AgentProfileGenerator::WslSourceCache::Snapshot AgentProfileGenerator::WslSourceCache::Read()
{
    std::scoped_lock lock{ _mutex };
    const auto previous = _cache.Previous();
    return previous ? *previous : Snapshot{};
}

bool AgentProfileGenerator::WslSourceCache::Refresh(const std::chrono::steady_clock::time_point now,
                                                    const std::function<std::optional<Snapshot>()>& probe)
{
    {
        std::scoped_lock lock{ _mutex };
        if (_refreshing || !_cache.NeedsRefresh(now))
        {
            return false;
        }
        _refreshing = true;
    }
    const auto finished = wil::scope_exit([&] {
        std::scoped_lock lock{ _mutex };
        _refreshing = false;
    });
    try
    {
        auto sources = probe();
        if (!sources)
        {
            return false;
        }
        std::scoped_lock lock{ _mutex };
        const auto previous = _cache.Previous();
        RetainKnownWslAgents(*sources, previous);
        const auto changed = WslProfileEvidence(*sources) != WslProfileEvidence(previous ? *previous : Snapshot{});
        _cache.Store(std::chrono::steady_clock::now(), std::move(*sources));
        return changed;
    }
    CATCH_LOG();
    return false;
}

bool AgentProfileGenerator::RefreshWslSources()
{
    return WslCache().Refresh(std::chrono::steady_clock::now(), [] {
        return ::Microsoft::Terminal::AgentAvailability::ProbeWslAgentSources();
    });
}

void AgentProfileGenerator::GenerateProfiles(std::vector<winrt::com_ptr<implementation::Profile>>& profiles) const
{
    static std::mutex mutex;
    static DiscoveryCache cache;
    DiscoveryCache::Snapshot host;
    {
        std::scoped_lock lock{ mutex };
        host = cache.Get(std::chrono::steady_clock::now(), [] {
            return AgentProfiles::Discover(AgentProfiles::NativePath());
        });
    }
    GenerateProfiles(profiles, host, WslCache().Read());
}

void AgentProfileGenerator::GenerateProfiles(std::vector<winrt::com_ptr<implementation::Profile>>& profiles,
                                             const DiscoveryCache::Snapshot& host,
                                             const WslDiscoveryCache::Snapshot& wsl)
{
    namespace Registry = ::Microsoft::Terminal::Settings::Model::AgentRegistry;
    auto sortedSources = wsl;
    std::ranges::sort(sortedSources, {}, &::Microsoft::Terminal::AgentAvailability::AgentSourceSnapshot::distro);
    const auto append = [&](const auto& agent, const std::wstring_view distro, const std::wstring_view executable) {
        const auto backend = distro.empty() ? std::wstring{ agent.id } :
                                              ::Microsoft::Terminal::Settings::Model::AgentPaneBackend::Wsl(distro, agent.id);
        const auto identity = std::wstring{ AgentProfiles::Source } + L":" + backend;
        auto profile = CreateDynamicProfile(identity);
        profile->Name(winrt::hstring{ std::wstring{ agent.displayName } + (distro.empty() ? L"" : L" (" + std::wstring{ distro } + L")") });
        profile->Icon(winrt::hstring{ L"ms-appx:///AgentIcons/" + std::wstring{ agent.id } + L".svg" });
        profile->AgentProfileId(winrt::hstring{ agent.id });
        profile->AgentProfileSource(winrt::hstring{ distro.empty() ? L"host" : L"wsl:" + std::wstring{ distro } });
        profile->Commandline(winrt::hstring{ distro.empty() ?
                                                 AgentProfiles::BuildCommand(executable, agent.id, {}, {}, {}) :
                                                 AgentProfiles::BuildWslCommand(distro, agent.id, {}, {}, {}) });
        if (!distro.empty())
        {
            profile->StartingDirectory(L"~");
            profile->PathTranslationStyle(winrt::Microsoft::Terminal::Control::PathTranslationStyle::WSL);
        }
        profiles.emplace_back(std::move(profile));
    };
    for (const auto& agent : Registry::BuiltinNativeProfileAgents)
    {
        if (!::Microsoft::Terminal::Settings::Model::AgentPolicy::IsAgentAllowed(agent.id))
        {
            continue;
        }
        if (const auto found = host.find(std::wstring{ agent.id }); found != host.end())
        {
            append(agent, {}, found->second.native());
        }
        std::set<std::wstring> emitted;
        for (const auto& source : sortedSources)
        {
            if (::Microsoft::Terminal::WslDistroName::IsSafe(std::wstring_view{ source.distro }) &&
                !source.distro.starts_with(L"docker-desktop") && !source.distro.starts_with(L"rancher-desktop") &&
                source.agentIds.contains(std::wstring{ agent.id }) && emitted.emplace(source.distro).second)
            {
                append(agent, source.distro, {});
            }
        }
    }
}
