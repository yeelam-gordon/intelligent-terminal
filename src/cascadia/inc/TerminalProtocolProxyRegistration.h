// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include <objbase.h>
#include <objidl.h>
#include "ITerminalProtocol.h"

#include <mutex>
#include <string>

#include <wil/stl.h>
#include <wil/win32_helpers.h>
#include <wil/resource.h>
#include <wil/result.h>
#include <wrl/client.h>

struct tagProxyFileInfo;

namespace Microsoft::Terminal::Protocol
{
    namespace details
    {
        using GetProxyDllInfo = void(WINAPI*)(const tagProxyFileInfo***, const CLSID**);
        using DllGetClassObject = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, void**);

        [[nodiscard]] inline std::wstring GetExecutableLocalProxyPath()
        {
            auto executablePath = wil::GetModuleFileNameW<std::wstring>(nullptr);
            const auto filenameOffset = executablePath.find_last_of(L"\\/");
            THROW_HR_IF(E_UNEXPECTED, filenameOffset == std::wstring::npos);
            executablePath.resize(filenameOffset + 1);
            executablePath.append(L"OpenConsoleProxy.dll");
            return executablePath;
        }

        [[nodiscard]] inline wil::unique_hmodule LoadAndVerifyProxyDll(const std::wstring& expectedPath)
        {
            wil::unique_hmodule module{ LoadLibraryExW(expectedPath.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32) };
            THROW_LAST_ERROR_IF_NULL(module);

            // Check the returned module, not just the path we asked Windows to load.
            const auto actualLoadedPath = wil::GetModuleFileNameW<std::wstring>(module.get());
            THROW_HR_IF(HRESULT_FROM_WIN32(ERROR_INVALID_DLL),
                        CompareStringOrdinal(expectedPath.c_str(), -1, actualLoadedPath.c_str(), -1, TRUE) != CSTR_EQUAL);
            return module;
        }

        class ProxyRegistration
        {
        public:
            [[nodiscard]] HRESULT LoadAndRegister() noexcept
            try
            {
                std::lock_guard lock{ _mutex };
                if (_cookie)
                {
                    return S_OK;
                }

                const auto expectedPath = GetExecutableLocalProxyPath();
                auto module = LoadAndVerifyProxyDll(expectedPath);

                const auto getProxyDllInfo = reinterpret_cast<GetProxyDllInfo>(GetProcAddress(module.get(), "GetProxyDllInfo"));
                RETURN_LAST_ERROR_IF_NULL(getProxyDllInfo);
                const auto dllGetClassObject = reinterpret_cast<DllGetClassObject>(GetProcAddress(module.get(), "DllGetClassObject"));
                RETURN_LAST_ERROR_IF_NULL(dllGetClassObject);

                const tagProxyFileInfo** proxyFileList = nullptr;
                const CLSID* proxyClsid = nullptr;
                getProxyDllInfo(&proxyFileList, &proxyClsid);
                RETURN_HR_IF(E_UNEXPECTED, !proxyFileList || !proxyClsid);

                Microsoft::WRL::ComPtr<IPSFactoryBuffer> factory;
                RETURN_IF_FAILED(dllGetClassObject(*proxyClsid, IID_PPV_ARGS(factory.GetAddressOf())));

                // Revoking the factory does not destroy outstanding COM proxies.
                // Keep their code loaded until process exit, including after shutdown.
                HMODULE pinnedModule = nullptr;
                RETURN_IF_WIN32_BOOL_FALSE(GetModuleHandleExW(
                    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                    reinterpret_cast<LPCWSTR>(module.get()),
                    &pinnedModule));

                DWORD cookie = 0;
                RETURN_IF_FAILED(CoRegisterClassObject(
                    *proxyClsid,
                    factory.Get(),
                    CLSCTX_INPROC_SERVER,
                    REGCLS_MULTIPLEUSE,
                    &cookie));

                auto revokeOnFailure = wil::scope_exit([&]() noexcept {
                    LOG_IF_FAILED(CoRevokeClassObject(cookie));
                });
                RETURN_IF_FAILED(CoRegisterPSClsid(__uuidof(ITerminalProtocol), *proxyClsid));
                RETURN_IF_FAILED(CoRegisterPSClsid(__uuidof(ITerminalProtocolEventSink), *proxyClsid));

                _cookie = cookie;
                revokeOnFailure.release();
                return S_OK;
            }
            CATCH_RETURN()

            [[nodiscard]] HRESULT Unregister() noexcept
            {
                std::lock_guard lock{ _mutex };
                if (!_cookie)
                {
                    return S_OK;
                }

                const auto hr = CoRevokeClassObject(_cookie);
                if (SUCCEEDED(hr))
                {
                    _cookie = 0;
                }
                return hr;
            }

        private:
            std::mutex _mutex;
            DWORD _cookie = 0;
        };

        inline ProxyRegistration& ProxyRegistrationInstance() noexcept
        {
            static ProxyRegistration registration;
            return registration;
        }
    }

    [[nodiscard]] inline HRESULT LoadAndRegisterLocalProxyDll() noexcept
    {
        return details::ProxyRegistrationInstance().LoadAndRegister();
    }

    [[nodiscard]] inline HRESULT UnregisterTerminalProtocolProxy() noexcept
    {
        return details::ProxyRegistrationInstance().Unregister();
    }
}
