// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include <array>
#include <string>
#include <string_view>

namespace Microsoft::Terminal::Settings::Model::AcpAgentPresets
{
    // Reviewed, local snapshot. Never fetch commands or artwork at runtime.
    inline constexpr std::wstring_view Revision{ L"2a27ff18b5816f47d7ec538e22943ff194e05131" };
    struct Preset
    {
        std::wstring_view id;
        std::wstring_view name;
        // Empty means explicit installation/environment configuration is needed.
        // Do not turn archive-relative paths into executable names on PATH.
        std::wstring_view command;
        std::wstring_view builtinIcon;
    };

    // Source: agentclientprotocol/registry/<revision>/<id>/agent.json.
    // Quarantined entries are deliberately not offered. Args/env must not be dropped.
    inline constexpr std::array Presets{
        Preset{ L"amp-acp", L"Amp", L"", L"" },
        Preset{ L"antigravity-acp", L"Google Antigravity", L"", L"antigravity" },
        Preset{ L"auggie", L"Auggie CLI", L"", L"" },
        Preset{ L"autohand", L"Autohand Code", L"", L"" },
        Preset{ L"bob", L"Bob", L"npx --yes @ibm/bob@2.1.0 acp", L"" },
        Preset{ L"claude-acp", L"Claude Agent", L"npx --yes @agentclientprotocol/claude-agent-acp@0.110.0", L"claude" },
        Preset{ L"cline", L"Cline", L"npx --yes cline@3.0.75 --acp", L"" },
        Preset{ L"codebuddy-code", L"Codebuddy Code", L"npx --yes @tencent-ai/codebuddy-code@2.185.0 --acp", L"" },
        Preset{ L"codex-acp", L"Codex", L"npx --yes @agentclientprotocol/codex-acp@2.10.0", L"codex" },
        Preset{ L"cortex-code", L"Cortex Code", L"", L"" },
        Preset{ L"corust-agent", L"Corust Agent", L"", L"" },
        Preset{ L"crow-cli", L"crow-cli", L"", L"" },
        Preset{ L"cursor", L"Cursor", L"", L"" },
        Preset{ L"devin", L"Devin", L"", L"" },
        Preset{ L"dimcode", L"DimCode", L"npx --yes dimcode@0.5.32 acp", L"" },
        Preset{ L"dirac", L"Dirac", L"npx --yes dirac-cli@0.6.1 --acp", L"" },
        Preset{ L"factory-droid", L"Factory Droid", L"", L"" },
        Preset{ L"fast-agent", L"fast-agent", L"", L"" },
        Preset{ L"gemini", L"Gemini CLI", L"npx --yes @google/gemini-cli@0.70.0 --acp", L"gemini" },
        Preset{ L"github-copilot-cli", L"GitHub Copilot CLI", L"npx --yes @github/copilot@1.0.114 --acp", L"copilot" },
        Preset{ L"github-copilot", L"GitHub Copilot Language Server", L"npx --yes @github/copilot-language-server@1.574.0 --acp", L"copilot" },
        Preset{ L"glm-acp-agent", L"GLM Agent", L"npx --yes glm-acp-agent@1.17.1", L"" },
        Preset{ L"goose", L"goose", L"", L"" },
        Preset{ L"grok-build", L"Grok Build", L"npx --yes @xai-official/grok@1.0.93 agent stdio", L"" },
        Preset{ L"harn", L"Harn", L"", L"" },
        Preset{ L"junie", L"Junie", L"", L"" },
        Preset{ L"kilo", L"Kilo", L"npx --yes @kilocode/cli@7.8.32 acp", L"" },
        Preset{ L"kimchi", L"Kimchi", L"", L"" },
        Preset{ L"kimi-code", L"Kimi Code", L"npx --yes @moonshot-ai/kimi-code@2.7.3 acp", L"" },
        Preset{ L"kimi", L"Kimi CLI (Legacy)", L"", L"" },
        Preset{ L"kiro", L"Kiro CLI", L"", L"" },
        Preset{ L"minimax-code", L"MiniMax Code", L"npx --yes @minimax-ai/code-acp@0.7.9 acp", L"" },
        Preset{ L"mistral-vibe", L"Mistral Vibe", L"", L"" },
        Preset{ L"muse-code", L"Muse Code", L"", L"" },
        Preset{ L"nova", L"Nova", L"npx --yes @compass-ai/nova@1.1.68 acp", L"" },
        Preset{ L"opencode", L"OpenCode", L"", L"opencode" },
        Preset{ L"pi-acp", L"pi ACP", L"npx --yes pi-acp@0.0.35", L"" },
        Preset{ L"poolside", L"Poolside", L"", L"" },
        Preset{ L"qoder", L"Qoder CLI", L"npx --yes @qoder-ai/qodercli@1.1.96 --acp", L"" },
        Preset{ L"qwen-code", L"Qwen Code", L"npx --yes @qwen-code/qwen-code@0.28.4 --acp --experimental-skills", L"" },
        Preset{ L"sigit", L"siGit Code", L"npx --yes @smbcloud/sigit@1.7.10", L"" },
        Preset{ L"stakpak", L"Stakpak", L"", L"" },
    };

    inline const Preset* Find(const std::wstring_view id) noexcept
    {
        for (const auto& preset : Presets)
        {
            if (preset.id == id)
            {
                return &preset;
            }
        }
        return nullptr;
    }

    inline const Preset* FindByCustomId(std::wstring_view id) noexcept
    {
        constexpr std::wstring_view prefix{ L"custom:acp-registry-" };
        return id.starts_with(prefix) ? Find(id.substr(prefix.size())) : nullptr;
    }

    inline std::wstring IconPath(const Preset& preset, const bool mask = false)
    {
        const auto builtin = !preset.builtinIcon.empty();
        return std::wstring{ L"ms-appx:///AgentIcons/" } +
               (builtin ? L"" : L"Registry/") + (mask ? L"Masks/" : L"") +
               std::wstring{ builtin ? preset.builtinIcon : preset.id } + (mask ? L".png" : L".svg");
    }
}
