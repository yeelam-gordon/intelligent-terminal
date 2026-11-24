// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include "CustomAgentId.h"
#include "NamedCustomAcpCommands.h"
#include <algorithm>
#include <json/json.h>
#include <stdexcept>

namespace Microsoft::Terminal::Settings::Model
{
    inline Json::Value ProjectCustomAcpAgentCommands(const Json::Value& settings)
    {
        if (!settings.isObject())
        {
            throw std::invalid_argument("custom ACP settings root must be an object");
        }
        Json::Value commands{ Json::objectValue };
        const auto append = [&](const Json::Value& value) {
            if (!value.isNull() && !value.isString())
            {
                throw std::invalid_argument("custom ACP command must be a string or null");
            }
            if (value.isNull() || value.asString().empty())
            {
                return;
            }
            const auto command = winrt::to_hstring(value.asString());
            auto id = "custom:" + winrt::to_string(DeriveCustomAgentId(command));
            std::ranges::transform(id, id.begin(), [](const unsigned char ch) { return static_cast<char>(ch >= 'A' && ch <= 'Z' ? ch + ('a' - 'A') : ch); });
            if (id != "custom:" && !commands.isMember(id))
            {
                commands[id] = value;
            }
        };
        const auto& plural = settings["acpCustomCommands"];
        if (plural.isArray())
        {
            for (const auto& command : plural)
            {
                append(command);
            }
        }
        else
        {
            append(plural);
        }
        const auto& named = settings["acpNamedCustomCommands"];
        if (!named.isNull() && !named.isObject())
        {
            throw std::invalid_argument("named custom ACP commands must be an object");
        }
        bool selectedMirror = false;
        if (named.isObject())
        {
            const auto& selected = settings["acpAgent"];
            selectedMirror = selected.isString() && named.isMember(selected.asString());
            for (auto entry = named.begin(); entry != named.end(); ++entry)
            {
                if (!entry->isString())
                {
                    throw std::invalid_argument("named custom ACP command must be a string");
                }
                const auto key = entry.name();
                if (NamedCustomAcpCommands::IsValidId(winrt::to_hstring(key)) &&
                    NamedCustomAcpCommands::IsValidCommand(winrt::to_hstring(entry->asString())))
                {
                    commands[key] = *entry;
                }
            }
        }
        if (!selectedMirror)
        {
            append(settings["acpCustomCommand"]);
        }
        return commands;
    }
}
