// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include <objbase.h>

namespace Microsoft::Terminal::Protocol
{
    namespace details
    {
        inline constexpr IID TerminalProtocolIid{ 0x9C7E2A14, 0x3B5D, 0x4F8A, { 0xA2, 0xC9, 0x1E, 0x4F, 0x6B, 0x8D, 0x0A, 0x3C } };
        inline constexpr IID TerminalProtocolEventSinkIid{ 0x3D8F4B26, 0x5C7E, 0x4A9B, { 0xB1, 0xD0, 0x2F, 0x5A, 0x7C, 0x9E, 0x1B, 0x4D } };

#if defined(WT_BRANDING_RELEASE)
        inline constexpr CLSID OpenConsoleProxyClsid{ 0xBA251D6A, 0x94D2, 0x4523, { 0xAA, 0xA0, 0x94, 0x77, 0xEE, 0x21, 0x76, 0x6E } };
#elif defined(WT_BRANDING_PREVIEW)
        inline constexpr CLSID OpenConsoleProxyClsid{ 0x1833E661, 0xCC81, 0x4DD0, { 0x87, 0xC6, 0xC2, 0xF7, 0x4B, 0xD3, 0x9E, 0xFA } };
#elif defined(WT_BRANDING_CANARY)
        inline constexpr CLSID OpenConsoleProxyClsid{ 0x1D1852F4, 0xADAD, 0x42B6, { 0x9A, 0x43, 0x94, 0x37, 0xAA, 0xAD, 0x77, 0x17 } };
#else
        inline constexpr CLSID OpenConsoleProxyClsid{ 0xDEC4804D, 0x56D1, 0x4F73, { 0x9F, 0xBE, 0x68, 0x28, 0xE7, 0xC8, 0x5C, 0x56 } };
#endif

        [[nodiscard]] inline HRESULT RegisterAndVerifyProxy(const IID& interfaceId) noexcept
        {
            auto hr = CoRegisterPSClsid(interfaceId, OpenConsoleProxyClsid);
            if (FAILED(hr))
            {
                return hr;
            }

            CLSID registeredClsid{};
            hr = CoGetPSClsid(interfaceId, &registeredClsid);
            if (FAILED(hr))
            {
                return hr;
            }

            return InlineIsEqualGUID(registeredClsid, OpenConsoleProxyClsid) ? S_OK : E_UNEXPECTED;
        }
    }

    // The package manifest resolves this branding-specific CLSID to the
    // package-local proxy DLL. These IID mappings are process-local.
    [[nodiscard]] inline HRESULT RegisterTerminalProtocolProxy() noexcept
    {
        const auto protocolRegistration = details::RegisterAndVerifyProxy(details::TerminalProtocolIid);
        if (FAILED(protocolRegistration))
        {
            return protocolRegistration;
        }

        return details::RegisterAndVerifyProxy(details::TerminalProtocolEventSinkIid);
    }
}
