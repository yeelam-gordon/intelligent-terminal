// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include "AgentRegistry.h"
#include <algorithm>
#include <string_view>
#include <winrt/Windows.Foundation.Collections.h>

namespace Microsoft::Terminal::Settings::Model::NamedCustomAcpCommands
{
    // Explicit identities survive command/package updates; legacy executable-derived IDs are unchanged.
    inline bool IsValidId(std::wstring_view id) noexcept
    {
        if (!id.starts_with(L"custom:"))
        {
            return false;
        }
        id.remove_prefix(7);
        const auto alphanumeric = [](const wchar_t ch) {
            return (ch >= L'a' && ch <= L'z') || (ch >= L'0' && ch <= L'9');
        };
        if (id.empty() || !alphanumeric(id.front()) || !alphanumeric(id.back()) ||
            !std::ranges::all_of(id, [&](const wchar_t ch) { return alphanumeric(ch) || ch == L'-' || ch == L'_' || ch == L'.'; }))
        {
            return false;
        }
        return std::ranges::none_of(AgentRegistry::BuiltinAcpAgents, [&](const auto& agent) { return agent.id == id; });
    }

    inline bool IsValidCommand(const std::wstring_view command) noexcept
    {
        return command.find(L'\0') == std::wstring_view::npos &&
               command.find_first_not_of(L" \t\r\n") != std::wstring_view::npos;
    }

    using CommandMap = winrt::Windows::Foundation::Collections::IMap<winrt::hstring, winrt::hstring>;

    inline bool HasSelectedBinding(const winrt::hstring& selected, const CommandMap& named)
    {
        // The singular compatibility field belongs to the named selection, even if its mirror is stale.
        // Invalid named bindings must not leak their mirrors into legacy execution either.
        return named && named.HasKey(selected);
    }
}
