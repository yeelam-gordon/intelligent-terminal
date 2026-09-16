// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include <unknwn.h>
#include <winrt/Windows.Foundation.h>

#include "Formatting.h"
#include "wtcli_functions.h"
#include "../../cascadia/inc/IntelligentTerminalPaths.h"
#include "../../cascadia/TerminalProtocol/PersistentSessionProtocol.h"
#include "../../cascadia/TerminalProtocol/ProtocolParsing.h"
#include "../../cascadia/TerminalProtocol/TerminalProtocolGuids.h"

// Classic-COM Terminal protocol. Generated from
// src/host/proxy/ITerminalProtocol.idl; found via the OpenConsoleProxy IntDir
// added to this project's include path. Marshaled by the OpenConsoleProxy
// proxy/stub (NOT WinRT MBM), so activation/marshaling never hits the combase
// WinRT activation catalog.
#include "ITerminalProtocol.h"

#include <CLI/CLI.hpp>

#include <wil/resource.h>

#include <algorithm>
#include <atomic>
#include <array>
#include <cctype>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <fcntl.h>
#include <io.h>
#include <iostream>
#include <mutex>
#include <optional>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

// ── EventSink — pure classic-COM event sink for `listen` ──
struct EventSink : ITerminalProtocolEventSink
{
    LONG _ref{ 1 };
    std::function<void(const std::string&)> _handler;

    explicit EventSink(std::function<void(const std::string&)> handler) :
        _handler(std::move(handler)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv)
            return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(ITerminalProtocolEventSink))
        {
            *ppv = static_cast<ITerminalProtocolEventSink*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&_ref); }
    ULONG STDMETHODCALLTYPE Release() override
    {
        const auto r = InterlockedDecrement(&_ref);
        if (r == 0)
            delete this;
        return r;
    }
    HRESULT STDMETHODCALLTYPE OnEvent(BSTR eventJson) override
    {
        if (_handler)
            _handler(eventJson ? winrt::to_string(winrt::hstring{ eventJson }) : std::string{});
        return S_OK;
    }
};

// ── Helpers ──

static winrt::com_ptr<ITerminalProtocol> AuthenticateConnectedTerminal(winrt::com_ptr<ITerminalProtocol> server,
                                                                       bool* outAuthenticated = nullptr,
                                                                       std::string* outVersion = nullptr,
                                                                       bool skipAuthenticate = false,
                                                                       bool quiet = false,
                                                                       bool requireProtocolVersion = false)
{
    if (outAuthenticated)
        *outAuthenticated = false;
    if (outVersion)
        outVersion->clear();

    if (!server)
    {
        return nullptr;
    }

    if (skipAuthenticate)
    {
        return server;
    }

    BSTR rawAuth = nullptr;
    auto hr = server->Authenticate(nullptr, &rawAuth);
    bool parsed = false;
    bool authenticated = false;
    std::string version;
    if (SUCCEEDED(hr) && rawAuth)
    {
        Json::Value v;
        Json::CharReaderBuilder rb;
        std::string errs;
        auto s = winrt::to_string(winrt::hstring{ rawAuth });
        std::istringstream ss(s);
        if (Json::parseFromStream(rb, ss, &v, &errs) &&
            (!requireProtocolVersion || (v.isObject() && v["authenticated"].isBool() &&
                                         v["protocol_version"].isString())))
        {
            parsed = true;
            authenticated = v["authenticated"].asBool();
            version = v["protocol_version"].asString();
        }
    }
    if (rawAuth)
        SysFreeString(rawAuth);

    if (FAILED(hr))
    {
        if (!quiet)
            fprintf(stderr, "[wtcli] Authentication failed: 0x%08X\n", static_cast<uint32_t>(hr));
        return nullptr;
    }
    if (!parsed)
    {
        // Success HRESULT but a null/malformed auth payload is a broken
        // server contract — don't misreport it as a server rejection.
        if (!quiet)
            fprintf(stderr, "[wtcli] Authentication response missing or malformed (server contract error)\n");
        return nullptr;
    }
    if (!authenticated)
    {
        if (!quiet)
            fprintf(stderr, "[wtcli] Authentication rejected by server\n");
        return nullptr;
    }

    if (outAuthenticated)
        *outAuthenticated = authenticated;
    if (outVersion)
        *outVersion = version;
    return server;
}

static winrt::com_ptr<ITerminalProtocol> ConnectToTerminalByClsid(const std::wstring_view clsidValue,
                                                                  bool* outAuthenticated = nullptr,
                                                                  std::string* outVersion = nullptr,
                                                                  bool skipAuthenticate = false,
                                                                  bool quiet = false,
                                                                  bool requireProtocolVersion = false)
{
    CLSID cls{};
    if (FAILED(CLSIDFromString(clsidValue.data(), &cls)))
    {
        if (!quiet)
            fprintf(stderr, "[wtcli] Invalid CLSID: %ls\n", clsidValue.data());
        return nullptr;
    }

    winrt::com_ptr<ITerminalProtocol> server;
    const auto hr = CoCreateInstance(cls, nullptr, CLSCTX_LOCAL_SERVER, __uuidof(ITerminalProtocol), server.put_void());
    if (FAILED(hr))
    {
        if (!quiet)
            fprintf(stderr, "[wtcli] Connection failed: 0x%08X\n", static_cast<uint32_t>(hr));
        return nullptr;
    }
    return AuthenticateConnectedTerminal(std::move(server), outAuthenticated, outVersion, skipAuthenticate, quiet, requireProtocolVersion);
}

static winrt::com_ptr<ITerminalProtocol> ConnectToTerminal(bool* outAuthenticated = nullptr,
                                                           std::string* outVersion = nullptr,
                                                           bool skipAuthenticate = false,
                                                           bool quiet = false,
                                                           bool requireProtocolVersion = false)
{
    wchar_t clsid[128]{};
    if (!GetEnvironmentVariableW(L"WT_COM_CLSID", clsid, ARRAYSIZE(clsid)))
    {
        if (!quiet)
            fprintf(stderr, "[wtcli] WT_COM_CLSID not set. Must run inside an Intelligent Terminal pane.\n");
        return nullptr;
    }
    return ConnectToTerminalByClsid(clsid, outAuthenticated, outVersion, skipAuthenticate, quiet, requireProtocolVersion);
}

static DWORD CurrentProcessSessionId() noexcept
{
    DWORD sessionId = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &sessionId);
    return sessionId;
}

static bool IsCurrentProcessInteractiveDesktop() noexcept
{
    if (CurrentProcessSessionId() == 0)
    {
        return false;
    }

    // GetProcessWindowStation returns a borrowed handle owned by the process.
    const auto windowStation = GetProcessWindowStation();
    if (!windowStation)
    {
        return false;
    }

    USEROBJECTFLAGS flags{};
    if (!GetUserObjectInformationW(windowStation, UOI_FLAGS, &flags, sizeof(flags), nullptr) ||
        (flags.dwFlags & WSF_VISIBLE) == 0)
    {
        return false;
    }

    wil::unique_hdesk inputDesktop{ OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS) };
    return inputDesktop.is_valid();
}

static winrt::com_ptr<ITerminalProtocol> ConnectToTerminalForSessionHost(bool* outAuthenticated = nullptr,
                                                                         std::string* outVersion = nullptr,
                                                                         bool skipAuthenticate = false,
                                                                         bool quiet = false,
                                                                         bool requireProtocolVersion = false,
                                                                         bool allowBrandedFallbackActivation = true)
{
    wchar_t clsid[128]{};
    if (GetEnvironmentVariableW(L"WT_COM_CLSID", clsid, ARRAYSIZE(clsid)))
    {
        return ConnectToTerminalByClsid(clsid, outAuthenticated, outVersion, skipAuthenticate, quiet, requireProtocolVersion);
    }
    if (!allowBrandedFallbackActivation)
    {
        if (!quiet)
        {
            fprintf(stderr, "[wtcli] WT_COM_CLSID is unavailable in this context; direct persistent-session control requires an interactive desktop session.\n");
        }
        return nullptr;
    }
    return ConnectToTerminalByClsid(winrt::to_hstring(__CLSID_TerminalProtocolServer).c_str(), outAuthenticated, outVersion, skipAuthenticate, quiet, requireProtocolVersion);
}

// Call a method that returns a JSON BSTR; parse into `out`. Returns the HRESULT.
template<typename F>
static HRESULT CallJson(F&& call, Json::Value& out)
{
    BSTR raw = nullptr;
    HRESULT hr = call(&raw);
    if (SUCCEEDED(hr))
    {
        bool parsed = false;
        if (raw)
        {
            Json::CharReaderBuilder rb;
            std::string errs;
            auto s = winrt::to_string(winrt::hstring{ raw });
            std::istringstream ss(s);
            parsed = Json::parseFromStream(rb, ss, &out, &errs);
        }
        // A success HRESULT with a null BSTR or malformed JSON is a broken
        // server contract; surface it as an error so callers' FAILED(hr)
        // checks fire immediately instead of proceeding with a
        // default-constructed `out`.
        if (!parsed)
            hr = E_UNEXPECTED;
    }
    if (raw)
        SysFreeString(raw);
    return hr;
}

static std::string GuidToString(const GUID& g)
{
    wchar_t buf[40]{};
    StringFromGUID2(g, buf, ARRAYSIZE(buf));
    std::wstring ws(buf);
    if (ws.size() > 2 && ws.front() == L'{' && ws.back() == L'}')
        ws = ws.substr(1, ws.size() - 2);
    return winrt::to_string(winrt::hstring{ ws });
}

static std::wstring GuidToWideString(const GUID& g)
{
    wchar_t buf[40]{};
    StringFromGUID2(g, buf, ARRAYSIZE(buf));
    std::wstring ws(buf);
    if (ws.size() > 2 && ws.front() == L'{' && ws.back() == L'}')
        ws = ws.substr(1, ws.size() - 2);
    return ws;
}

static std::wstring CreateGuidString()
{
    GUID guid{};
    THROW_IF_FAILED(CoCreateGuid(&guid));
    return GuidToWideString(guid);
}

static GUID GuidFromString(const std::string& target, bool quiet = false)
{
    auto wstr = winrt::to_hstring(target);
    std::wstring guidStr{ wstr };
    if (!guidStr.empty() && guidStr[0] != L'{')
        guidStr = L"{" + guidStr + L"}";
    GUID g{};
    if (FAILED(CLSIDFromString(guidStr.c_str(), &g)))
    {
        if (!quiet && !target.empty())
            fprintf(stderr, "[wtcli] Invalid session ID: %s\n", target.c_str());
        return GUID{};
    }
    return g;
}

// Resolve a session id: an explicit GUID string, or the active pane's id.
static GUID ResolveSessionId(ITerminalProtocol* server, const std::string& target)
{
    if (!target.empty())
        return GuidFromString(target);

    Json::Value info;
    const auto hr = CallJson([&](BSTR* j) { return server->GetActivePane(j); }, info);
    if (FAILED(hr))
    {
        fprintf(stderr, "[wtcli] Could not resolve active pane (GetActivePane failed: 0x%08X)\n", static_cast<uint32_t>(hr));
        return GUID{};
    }
    const auto sessionId = info["session_id"].asString();
    if (sessionId.empty())
    {
        fprintf(stderr, "[wtcli] No active pane.\n");
        return GUID{};
    }
    return GuidFromString(sessionId);
}

static uint64_t GetFirstWindowId(ITerminalProtocol* server)
{
    Json::Value windows;
    CallJson([&](BSTR* j) { return server->ListWindows(j); }, windows);
    if (windows.isArray() && !windows.empty())
        return windows[0u]["window_id"].asUInt64();
    return 0;
}

static uint32_t GetFirstTabId(ITerminalProtocol* server, uint64_t windowId)
{
    Json::Value tabs;
    CallJson([&](BSTR* j) { return server->ListTabs(windowId, j); }, tabs);
    if (tabs.isArray() && !tabs.empty())
        return tabs[0u]["tab_id"].asUInt();
    return UINT32_MAX;
}

// Allocate a BSTR from a UTF-8 std::string.
static BSTR Bstr(const std::string& s)
{
    return SysAllocString(winrt::to_hstring(s).c_str());
}

static std::string EnvironmentValue(const wchar_t* name)
{
    const auto required = GetEnvironmentVariableW(name, nullptr, 0);
    if (required == 0)
    {
        return {};
    }

    std::wstring value(required, L'\0');
    const auto written = GetEnvironmentVariableW(name, value.data(), required);
    if (written == 0 || written >= required)
    {
        return {};
    }
    value.resize(written);
    return winrt::to_string(winrt::hstring{ value });
}

static std::string AgentSessionIdFromEnvironment(const std::string& cliSource)
{
    if (cliSource == "copilot")
        return EnvironmentValue(L"COPILOT_SESSION_ID");
    if (cliSource == "claude")
        return EnvironmentValue(L"CLAUDE_SESSION_ID");
    if (cliSource == "gemini")
        return EnvironmentValue(L"GEMINI_SESSION_ID");
    if (cliSource == "codex")
        return EnvironmentValue(L"CODEX_SESSION_ID");
    return {};
}

// Parse a base-10 unsigned 64-bit integer without throwing (unlike std::stoull,
// which aborts wtcli on non-numeric input). Returns false on empty, non-numeric,
// trailing-garbage, or overflowing input.
static bool TryParseU64(const std::string& s, uint64_t& out)
{
    if (s.empty())
        return false;
    uint64_t v = 0;
    const auto* first = s.data();
    const auto* last = s.data() + s.size();
    const auto [ptr, ec] = std::from_chars(first, last, v);
    if (ec != std::errc{} || ptr != last)
        return false;
    out = v;
    return true;
}

static HRESULT ProtocolAtLeast(const std::string& version, const unsigned requiredMajor, const unsigned requiredMinor)
{
    const auto dot = version.find('.');
    if (dot == std::string::npos)
    {
        return E_UNEXPECTED;
    }

    uint64_t major = 0;
    uint64_t minor = 0;
    if (!TryParseU64(version.substr(0, dot), major) ||
        !TryParseU64(version.substr(dot + 1), minor))
    {
        return E_UNEXPECTED;
    }
    return major > requiredMajor || (major == requiredMajor && minor >= requiredMinor) ? S_OK : S_FALSE;
}

static HRESULT SupportsCapability(ITerminalProtocol* server, const std::string_view capability)
{
    Json::Value capabilities;
    const auto hr = CallJson([&](BSTR* json) { return server->GetCapabilities(json); }, capabilities);
    if (FAILED(hr))
    {
        return hr;
    }

    using namespace Microsoft::Terminal::Protocol::Parsing;
    switch (ClassifyCapability(capabilities, capability))
    {
    case CapabilitySupport::Supported:
        return S_OK;
    case CapabilitySupport::Unsupported:
        return S_FALSE;
    default:
        return E_UNEXPECTED;
    }
}

namespace SessionWire = Microsoft::Terminal::PersistentSession;

namespace PersistentSessions
{
    constexpr std::wstring_view HostPipePrefix{ L"\\\\.\\pipe\\IntelligentTerminal.SessionHost." };

    struct HostRecord
    {
        DWORD desktopSessionId{};
        DWORD pid{};
        std::wstring pipeName;
        std::wstring ownerSid;
        std::wstring generation;
        std::wstring instanceId;
        std::filesystem::path discoveryPath;
    };

    struct ConsoleModeGuard
    {
        HANDLE handle{ INVALID_HANDLE_VALUE };
        DWORD originalMode{};
        bool active{ false };

        ~ConsoleModeGuard()
        {
            if (active)
            {
                SetConsoleMode(handle, originalMode);
            }
        }
    };

    static std::string JsonString(const Json::Value& value)
    {
        Json::StreamWriterBuilder builder;
        builder["indentation"] = "";
        return Json::writeString(builder, value);
    }

    static bool ParseJsonString(const std::string& text, Json::Value& value)
    {
        Json::CharReaderBuilder builder;
        std::string errors;
        std::istringstream stream(text);
        return Json::parseFromStream(builder, stream, &value, &errors);
    }

    static std::string AsciiLower(std::string value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](const unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
        return value;
    }

    static std::string ReadUtf8File(const std::filesystem::path& path)
    {
        std::ifstream file(path, std::ios::binary);
        if (!file)
        {
            return {};
        }
        return { std::istreambuf_iterator<char>{ file }, std::istreambuf_iterator<char>{} };
    }

    static void WriteUtf8FileAtomic(const std::filesystem::path& path, const std::string_view content)
    {
        auto tempPath = path;
        tempPath += L".tmp";

        {
            std::ofstream file(tempPath, std::ios::binary | std::ios::trunc);
            if (!file)
            {
                THROW_HR(E_FAIL);
            }
            file.write(content.data(), static_cast<std::streamsize>(content.size()));
            file.close();
            THROW_HR_IF(E_FAIL, !file.good());
        }

        std::error_code ec;
        std::filesystem::rename(tempPath, path, ec);
        if (ec)
        {
            std::filesystem::remove(path, ec);
            ec.clear();
            std::filesystem::rename(tempPath, path, ec);
            THROW_HR_IF(HRESULT_FROM_WIN32(ec.value()), ec);
        }
    }

    static std::filesystem::path DiscoveryDirectory()
    {
        return IntelligentTerminal::PersistentSessionHostDir();
    }

    static std::filesystem::path DiscoveryPathForSession(const DWORD desktopSessionId)
    {
        return DiscoveryDirectory() / (L"desktop-session-" + std::to_wstring(desktopSessionId) + L".json");
    }

    static bool LoadHostRecord(const std::filesystem::path& path, HostRecord& record)
    {
        const auto text = ReadUtf8File(path);
        if (text.empty())
        {
            return false;
        }

        Json::Value root;
        wtcli::PersistentSessionHostDiscoveryRecord parsed;
        if (!ParseJsonString(text, root) || !wtcli::TryParsePersistentSessionHostDiscoveryRecord(root, parsed))
        {
            return false;
        }
        record.desktopSessionId = static_cast<DWORD>(parsed.desktopSessionId);
        record.pid = static_cast<DWORD>(parsed.pid);
        record.pipeName = winrt::to_hstring(parsed.pipeName).c_str();
        record.ownerSid = winrt::to_hstring(parsed.ownerSid).c_str();
        record.generation = winrt::to_hstring(parsed.generation).c_str();
        record.instanceId = winrt::to_hstring(parsed.instanceId).c_str();
        record.discoveryPath = path;
        return true;
    }

    static void WriteDiscoveryRecord(const HostRecord& record)
    {
        std::error_code ec;
        std::filesystem::create_directories(record.discoveryPath.parent_path(), ec);

        Json::Value root;
        root["desktop_session_id"] = static_cast<Json::UInt>(record.desktopSessionId);
        root["pid"] = static_cast<Json::UInt>(record.pid);
        root["pipe_name"] = winrt::to_string(winrt::hstring{ record.pipeName });
        root["owner_sid"] = winrt::to_string(winrt::hstring{ record.ownerSid });
        root["generation"] = winrt::to_string(winrt::hstring{ record.generation });
        root["instance_id"] = winrt::to_string(winrt::hstring{ record.instanceId });
        WriteUtf8FileAtomic(record.discoveryPath, JsonString(root));
    }

    static void RemoveDiscoveryRecordIfMatches(const HostRecord& record)
    {
        HostRecord current;
        if (!LoadHostRecord(record.discoveryPath, current))
        {
            return;
        }
        if (current.generation == record.generation && current.pipeName == record.pipeName)
        {
            std::error_code ec;
            std::filesystem::remove(record.discoveryPath, ec);
        }
    }

    static std::string CurrentUserSidUtf8()
    {
        return winrt::to_string(winrt::hstring{ SessionWire::CurrentUserSidString() });
    }

    static bool HostMatchesCurrentUser(const HostRecord& record, const std::string_view userSid)
    {
        return wtcli::EqualsCaseInsensitiveAscii(winrt::to_string(winrt::hstring{ record.ownerSid }), userSid);
    }

    static bool IsHostRecordDefinitelyStale(const HostRecord& record)
    {
        if (record.pid == 0)
        {
            return false;
        }

        wil::unique_handle process{ OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, record.pid) };
        if (!process)
        {
            return GetLastError() == ERROR_INVALID_PARAMETER;
        }

        DWORD sessionId = 0;
        if (ProcessIdToSessionId(record.pid, &sessionId) && sessionId != record.desktopSessionId)
        {
            return true;
        }

        return WaitForSingleObject(process.get(), 0) == WAIT_OBJECT_0;
    }

    static std::vector<HostRecord> DiscoverHosts()
    {
        std::vector<HostRecord> records;
        std::error_code ec;
        const auto dir = DiscoveryDirectory();
        if (!std::filesystem::exists(dir, ec))
        {
            return records;
        }

        for (const auto& entry : std::filesystem::directory_iterator(dir, ec))
        {
            if (ec || !entry.is_regular_file())
            {
                continue;
            }
            HostRecord record;
            if (LoadHostRecord(entry.path(), record))
            {
                if (IsHostRecordDefinitelyStale(record))
                {
                    std::filesystem::remove(entry.path(), ec);
                    ec.clear();
                    continue;
                }
                records.push_back(std::move(record));
            }
        }
        return records;
    }

    static std::vector<HostRecord> DiscoverHostsForCurrentUser(const std::string_view userSid)
    {
        std::vector<HostRecord> records;
        for (auto& record : DiscoverHosts())
        {
            if (HostMatchesCurrentUser(record, userSid))
            {
                records.push_back(std::move(record));
            }
        }
        return records;
    }

    static bool TryConfigureConsoleMode(const HANDLE handle, const DWORD newMode, ConsoleModeGuard& guard)
    {
        if (handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        DWORD mode = 0;
        if (!GetConsoleMode(handle, &mode))
        {
            return false;
        }
        guard.handle = handle;
        guard.originalMode = mode;
        guard.active = SetConsoleMode(handle, newMode) != FALSE;
        return guard.active;
    }

    static std::optional<SessionWire::ResizePayload> QueryConsoleSize()
    {
        CONSOLE_SCREEN_BUFFER_INFO info{};
        if (!GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info))
        {
            return std::nullopt;
        }
        const auto columns = info.srWindow.Right - info.srWindow.Left + 1;
        const auto rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (rows <= 0 || columns <= 0)
        {
            return std::nullopt;
        }
        return SessionWire::ResizePayload{
            .rows = static_cast<uint32_t>(rows),
            .columns = static_cast<uint32_t>(columns),
        };
    }

    static std::string HResultMessage(const HRESULT hr)
    {
        switch (hr)
        {
        case HRESULT_FROM_WIN32(ERROR_NOT_FOUND):
            return "No matching persistent session was found.";
        case HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS):
            return "A persistent session with that name already exists.";
        case HRESULT_FROM_WIN32(ERROR_PIPE_BUSY):
            return "That persistent session already has an active writer attached.";
        case HRESULT_FROM_WIN32(ERROR_INVALID_STATE):
            return "That persistent session is no longer running.";
        case HRESULT_FROM_WIN32(ERROR_DUP_NAME):
            return "Multiple persistent sessions matched that name; use the session ID.";
        default:
            return "The request failed.";
        }
    }

    static std::string AttachStreamFailureMessage(const HRESULT hr)
    {
        switch (hr)
        {
        case HRESULT_FROM_WIN32(ERROR_BROKEN_PIPE):
        case HRESULT_FROM_WIN32(ERROR_PIPE_NOT_CONNECTED):
        case HRESULT_FROM_WIN32(ERROR_BAD_PIPE):
        case HRESULT_FROM_WIN32(ERROR_NO_DATA):
            return "The persistent-session attachment disconnected unexpectedly.";
        default:
            return "The persistent-session attachment ended unexpectedly.";
        }
    }

    static bool IsStaleHostTransportError(const HRESULT hr) noexcept
    {
        switch (hr)
        {
        case HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND):
        case HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND):
        case HRESULT_FROM_WIN32(ERROR_BAD_PIPE):
        case HRESULT_FROM_WIN32(ERROR_PIPE_NOT_CONNECTED):
        case HRESULT_FROM_WIN32(ERROR_BROKEN_PIPE):
        case HRESULT_FROM_WIN32(ERROR_NO_DATA):
            return true;
        default:
            return false;
        }
    }

    static HRESULT SendControlRequest(const HostRecord& host, const Json::Value& request, Json::Value& response)
    {
        auto openPipe = [&]() -> wil::unique_hfile {
            return wil::unique_hfile{
                CreateFileW(host.pipeName.c_str(),
                            GENERIC_READ | GENERIC_WRITE,
                            0,
                            nullptr,
                            OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL,
                            nullptr)
            };
        };

        auto pipe = openPipe();
        if (!pipe && GetLastError() == ERROR_PIPE_BUSY)
        {
            if (!WaitNamedPipeW(host.pipeName.c_str(), 2000))
            {
                return HRESULT_FROM_WIN32(GetLastError());
            }
            pipe = openPipe();
        }

        if (!pipe)
        {
            const auto hr = HRESULT_FROM_WIN32(GetLastError());
            if (IsStaleHostTransportError(hr))
            {
                RemoveDiscoveryRecordIfMatches(host);
            }
            return hr;
        }

        HRESULT hr = SessionWire::WriteHello(pipe.get(), "client");
        if (FAILED(hr))
        {
            if (IsStaleHostTransportError(hr))
            {
                RemoveDiscoveryRecordIfMatches(host);
            }
            return hr;
        }
        Json::Value hello;
        hr = SessionWire::ReadAndValidateHello(pipe.get(), "host", hello);
        if (FAILED(hr))
        {
            if (IsStaleHostTransportError(hr))
            {
                RemoveDiscoveryRecordIfMatches(host);
            }
            return hr;
        }
        hr = SessionWire::WriteJsonFrame(pipe.get(), SessionWire::MessageType::Request, request);
        if (FAILED(hr))
        {
            if (IsStaleHostTransportError(hr))
            {
                RemoveDiscoveryRecordIfMatches(host);
            }
            return hr;
        }

        SessionWire::Frame frame;
        hr = SessionWire::ReadFrame(pipe.get(), frame);
        if (FAILED(hr))
        {
            if (IsStaleHostTransportError(hr))
            {
                RemoveDiscoveryRecordIfMatches(host);
            }
            return hr;
        }
        if (frame.type == SessionWire::MessageType::Error)
        {
            Json::Value error;
            RETURN_IF_FAILED(SessionWire::ParseJsonPayload(frame.payload, error));
            if (error["hr"].isInt())
            {
                return error["hr"].asInt();
            }
            return E_FAIL;
        }
        RETURN_HR_IF(E_UNEXPECTED, frame.type != SessionWire::MessageType::Response);
        return SessionWire::ParseJsonPayload(frame.payload, response);
    }

    static HRESULT ResolveHost(const std::optional<uint32_t> desiredSession, const std::string_view userSid, HostRecord& host)
    {
        auto hosts = DiscoverHosts();
        std::vector<wtcli::PersistentSessionHostDiscoveryRecord> candidates;
        candidates.reserve(hosts.size());
        for (const auto& candidate : hosts)
        {
            candidates.push_back(wtcli::PersistentSessionHostDiscoveryRecord{
                .desktopSessionId = candidate.desktopSessionId,
                .pid = candidate.pid,
                .pipeName = winrt::to_string(winrt::hstring{ candidate.pipeName }),
                .ownerSid = winrt::to_string(winrt::hstring{ candidate.ownerSid }),
                .generation = winrt::to_string(winrt::hstring{ candidate.generation }),
                .instanceId = winrt::to_string(winrt::hstring{ candidate.instanceId }),
            });
        }

        const auto selection = wtcli::SelectPersistentSessionHost(candidates, userSid, desiredSession);
        if (selection.status == wtcli::PersistentSessionHostSelectionStatus::Selected)
        {
            host = hosts[selection.selectedIndex];
            return S_OK;
        }

        return selection.status == wtcli::PersistentSessionHostSelectionStatus::Ambiguous ?
                   HRESULT_FROM_WIN32(ERROR_MORE_DATA) :
                   HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    static HRESULT AddHostMetadata(const HostRecord& host, Json::Value& response)
    {
        if (response.isArray())
        {
            for (auto& session : response)
            {
                session["desktop_session_id"] = static_cast<Json::UInt>(host.desktopSessionId);
                session["host_generation"] = winrt::to_string(winrt::hstring{ host.generation });
            }
        }
        else if (response.isObject())
        {
            response["desktop_session_id"] = static_cast<Json::UInt>(host.desktopSessionId);
            response["host_generation"] = winrt::to_string(winrt::hstring{ host.generation });
        }
        return S_OK;
    }

    static HRESULT ResolvePersistentSessionByTarget(ITerminalProtocol* server, const std::string& target, GUID& sessionId, Json::Value* sessionOut = nullptr)
    {
        Json::Value sessions;
        RETURN_IF_FAILED(CallJson([&](BSTR* json) { return server->ListPersistentSessions(json); }, sessions));
        RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_NOT_FOUND), !sessions.isArray());

        const auto lowerTarget = AsciiLower(target);
        std::optional<Json::Value> nameMatch;
        for (const auto& session : sessions)
        {
            if (!session.isObject() || !session["session_id"].isString())
            {
                continue;
            }

            const auto sessionIdText = session["session_id"].asString();
            const auto name = session["name"].isString() ? session["name"].asString() : std::string{};
            if (AsciiLower(sessionIdText) == lowerTarget)
            {
                sessionId = GuidFromString(sessionIdText, true);
                RETURN_HR_IF(E_INVALIDARG, InlineIsEqualGUID(sessionId, GUID{}));
                if (sessionOut)
                {
                    *sessionOut = session;
                }
                return S_OK;
            }

            if (!name.empty() && AsciiLower(name) == lowerTarget)
            {
                RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_DUP_NAME), nameMatch.has_value());
                nameMatch = session;
            }
        }

        if (nameMatch.has_value())
        {
            sessionId = GuidFromString((*nameMatch)["session_id"].asString(), true);
            RETURN_HR_IF(E_INVALIDARG, InlineIsEqualGUID(sessionId, GUID{}));
            if (sessionOut)
            {
                *sessionOut = *nameMatch;
            }
            return S_OK;
        }
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    static HRESULT HandleControlRequest(const Json::Value& request,
                                        Json::Value& response,
                                        const bool skipAuthenticate,
                                        const bool allowBrandedFallbackActivation)
    {
        RETURN_HR_IF(E_INVALIDARG, !request.isObject() || !request["command"].isString());

        auto server = ConnectToTerminalForSessionHost(nullptr, nullptr, skipAuthenticate, true, false, allowBrandedFallbackActivation);
        RETURN_HR_IF(E_FAIL, !server);

        const auto command = request["command"].asString();
        if (command == "list")
        {
            return CallJson([&](BSTR* json) { return server->ListPersistentSessions(json); }, response);
        }
        if (command == "create")
        {
            wil::unique_bstr profile{ Bstr(request["profile"].isString() ? request["profile"].asString() : std::string{}) };
            wil::unique_bstr commandline{ Bstr(request["commandline"].isString() ? request["commandline"].asString() : std::string{}) };
            wil::unique_bstr title{ Bstr(request["title"].isString() ? request["title"].asString() : std::string{}) };
            wil::unique_bstr cwd{ Bstr(request["cwd"].isString() ? request["cwd"].asString() : std::string{}) };
            const auto requestedName = request["name"].isString() ? request["name"].asString() : std::string{};

            if (!requestedName.empty())
            {
                GUID existingSessionId{};
                const auto existingHr = ResolvePersistentSessionByTarget(server.get(), requestedName, existingSessionId);
                RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS), SUCCEEDED(existingHr) || existingHr == HRESULT_FROM_WIN32(ERROR_DUP_NAME));
                RETURN_IF_FAILED(existingHr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND) ? S_OK : existingHr);
            }

            Json::Value created;
            RETURN_IF_FAILED(CallJson([&](BSTR* json) {
                return server->CreateTab(0, profile.get(), commandline.get(), title.get(), cwd.get(), false, true, json);
            },
                                      created));

            const auto sessionIdText = created["session_id"].asString();
            const auto sessionId = GuidFromString(sessionIdText, true);
            RETURN_HR_IF(E_FAIL, InlineIsEqualGUID(sessionId, GUID{}));

            wil::unique_bstr name{ Bstr(requestedName) };
            const auto markHr = server->MarkPersistentSession(sessionId, name.get());
            if (FAILED(markHr))
            {
                (void)server->ClosePane(sessionId);
                return markHr;
            }
            return CallJson([&](BSTR* json) { return server->InspectPersistentSession(sessionId, json); }, response);
        }
        if (!request["target"].isString())
        {
            return E_INVALIDARG;
        }

        GUID sessionId{};
        Json::Value session;
        RETURN_IF_FAILED(ResolvePersistentSessionByTarget(server.get(), request["target"].asString(), sessionId, &session));
        if (command == "inspect")
        {
            return CallJson([&](BSTR* json) { return server->InspectPersistentSession(sessionId, json); }, response);
        }
        if (command == "kill")
        {
            RETURN_IF_FAILED(server->ClosePane(sessionId));
            response["ok"] = true;
            response["session_id"] = session["session_id"].asString();
            return S_OK;
        }
        if (command == "attach")
        {
            return CallJson([&](BSTR* json) { return server->PreparePersistentSessionAttach(sessionId, json); }, response);
        }
        return E_INVALIDARG;
    }

    static int RunSessionHost(const bool jsonMode)
    {
        const auto desktopSessionId = CurrentProcessSessionId();
        if (desktopSessionId == 0 || !IsCurrentProcessInteractiveDesktop())
        {
            fprintf(stderr, "[wtcli] session host must run in an interactive user session after logon.\n");
            return 1;
        }

        HostRecord record;
        record.desktopSessionId = desktopSessionId;
        record.pid = GetCurrentProcessId();
        record.ownerSid = SessionWire::CurrentUserSidString();
        record.generation = CreateGuidString();
        record.instanceId = CreateGuidString();
        record.pipeName = std::wstring{ HostPipePrefix } + std::to_wstring(desktopSessionId) + L"." + record.generation;
        record.discoveryPath = DiscoveryPathForSession(desktopSessionId);

        if (!ConnectToTerminalForSessionHost(nullptr, nullptr, false, false, false, true))
        {
            fprintf(stderr, "[wtcli] session host could not connect to Intelligent Terminal in desktop session %lu.\n", static_cast<unsigned long>(desktopSessionId));
            return 1;
        }

        auto security = SessionWire::CreateUserAndSystemPipeSecurity();
        wil::unique_hfile listener{
            CreateNamedPipeW(record.pipeName.c_str(),
                             PIPE_ACCESS_DUPLEX,
                             PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                             1,
                             SessionWire::MaxControlPayloadBytes,
                             SessionWire::MaxControlPayloadBytes,
                             0,
                             security.get())
        };
        if (!listener)
        {
            fprintf(stderr, "[wtcli] session host pipe creation failed: 0x%08X\n", HRESULT_FROM_WIN32(GetLastError()));
            return 1;
        }

        WriteDiscoveryRecord(record);
        const auto cleanup = wil::scope_exit([&]() noexcept {
            RemoveDiscoveryRecordIfMatches(record);
        });

        if (jsonMode)
        {
            Json::Value info;
            info["desktop_session_id"] = static_cast<Json::UInt>(desktopSessionId);
            info["pipe_name"] = winrt::to_string(winrt::hstring{ record.pipeName });
            info["generation"] = winrt::to_string(winrt::hstring{ record.generation });
            PrintJson(info);
        }
        else
        {
            printf("Persistent session host listening for desktop session %lu.\n", static_cast<unsigned long>(desktopSessionId));
        }

        for (;;)
        {
            const auto connected = ConnectNamedPipe(listener.get(), nullptr);
            if (!connected && GetLastError() != ERROR_PIPE_CONNECTED)
            {
                fprintf(stderr, "[wtcli] session host connection failed: 0x%08X\n", HRESULT_FROM_WIN32(GetLastError()));
                return 1;
            }

            auto disconnect = wil::scope_exit([&]() noexcept {
                FlushFileBuffers(listener.get());
                DisconnectNamedPipe(listener.get());
            });

            Json::Value hello;
            auto hr = SessionWire::ReadAndValidateHello(listener.get(), "client", hello);
            if (FAILED(hr) || FAILED(hr = SessionWire::WriteHello(listener.get(), "host")))
            {
                continue;
            }

            Json::Value request;
            if (FAILED(SessionWire::ReadJsonFrame(listener.get(), SessionWire::MessageType::Request, request)))
            {
                continue;
            }

            Json::Value response;
            hr = HandleControlRequest(request, response, false, true);
            if (SUCCEEDED(hr))
            {
                (void)SessionWire::WriteJsonFrame(listener.get(), SessionWire::MessageType::Response, response);
            }
            else
            {
                Json::Value error;
                error["hr"] = static_cast<int32_t>(hr);
                error["message"] = HResultMessage(hr);
                (void)SessionWire::WriteJsonFrame(listener.get(), SessionWire::MessageType::Error, error);
            }
        }
    }

    static HRESULT SendAttachRequest(const Json::Value& attachInfo, std::optional<SessionWire::ResizePayload> initialSize, wil::unique_hfile& pipe)
    {
        const auto pipeName = winrt::to_hstring(attachInfo["pipe_name"].asString());
        pipe.reset(CreateFileW(pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!pipe)
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        RETURN_IF_FAILED(SessionWire::WriteHello(pipe.get(), "client"));
        Json::Value hello;
        RETURN_IF_FAILED(SessionWire::ReadAndValidateHello(pipe.get(), "terminal", hello));

        Json::Value request;
        request["command"] = "attach";
        request["token"] = attachInfo["attach_token"].asString();
        if (initialSize.has_value())
        {
            request["rows"] = initialSize->rows;
            request["columns"] = initialSize->columns;
        }
        RETURN_IF_FAILED(SessionWire::WriteJsonFrame(pipe.get(), SessionWire::MessageType::Request, request));

        SessionWire::Frame frame;
        RETURN_IF_FAILED(SessionWire::ReadFrame(pipe.get(), frame));
        if (frame.type == SessionWire::MessageType::Error)
        {
            Json::Value error;
            RETURN_IF_FAILED(SessionWire::ParseJsonPayload(frame.payload, error));
            return error["hr"].isInt() ? error["hr"].asInt() : E_FAIL;
        }
        RETURN_HR_IF(E_UNEXPECTED, frame.type != SessionWire::MessageType::Response);
        return S_OK;
    }

    static int RunAttachClient(const Json::Value& attachInfo)
    {
        wil::unique_hfile pipe;
        auto initialSize = QueryConsoleSize();
        if (!initialSize.has_value() && attachInfo["rows"].isUInt() && attachInfo["columns"].isUInt())
        {
            initialSize = SessionWire::ResizePayload{
                .rows = attachInfo["rows"].asUInt(),
                .columns = attachInfo["columns"].asUInt(),
            };
        }

        auto hr = SendAttachRequest(attachInfo, initialSize, pipe);
        if (FAILED(hr))
        {
            fprintf(stderr, "[wtcli] session attach failed: %s (0x%08X)\n", HResultMessage(hr).c_str(), static_cast<uint32_t>(hr));
            return 1;
        }

        (void)_setmode(_fileno(stdin), _O_BINARY);
        (void)_setmode(_fileno(stdout), _O_BINARY);

        ConsoleModeGuard inputGuard;
        ConsoleModeGuard outputGuard;
        {
            const auto in = GetStdHandle(STD_INPUT_HANDLE);
            DWORD mode = 0;
            if (GetConsoleMode(in, &mode))
            {
                const auto raw = (mode | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT) &
                                 ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
                (void)TryConfigureConsoleMode(in, raw, inputGuard);
            }
        }
        {
            const auto out = GetStdHandle(STD_OUTPUT_HANDLE);
            DWORD mode = 0;
            if (GetConsoleMode(out, &mode))
            {
                const auto vt = mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
                (void)TryConfigureConsoleMode(out, vt, outputGuard);
            }
        }

        std::mutex writeMutex;
        std::atomic<bool> stop{ false };
        std::atomic<bool> detachSent{ false };

        auto writeFrame = [&](const SessionWire::MessageType type, const std::span<const uint8_t> payload) -> bool {
            std::lock_guard lock{ writeMutex };
            return SUCCEEDED(SessionWire::WriteFrame(pipe.get(), type, payload));
        };

        std::thread inputThread([&]() {
            std::array<uint8_t, SessionWire::MaxDataPayloadBytes> buffer{};
            bool shouldDetach = false;
            for (;;)
            {
                if (stop.load())
                {
                    return;
                }

                DWORD read = 0;
                if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr))
                {
                    shouldDetach = true;
                    break;
                }
                if (read == 0)
                {
                    shouldDetach = true;
                    break;
                }
                if (!writeFrame(SessionWire::MessageType::Data, std::span<const uint8_t>{ buffer.data(), read }))
                {
                    break;
                }
            }

            stop = true;
            if (shouldDetach)
            {
                detachSent = true;
                (void)writeFrame(SessionWire::MessageType::Detach, {});
            }
        });

        std::thread resizeThread([&]() {
            auto lastSize = QueryConsoleSize();
            while (!stop.load())
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
                const auto current = QueryConsoleSize();
                if (current.has_value() && (!lastSize.has_value() || current->rows != lastSize->rows || current->columns != lastSize->columns))
                {
                    std::lock_guard lock{ writeMutex };
                    (void)SessionWire::WriteResizeFrame(pipe.get(), current->rows, current->columns);
                    lastSize = current;
                }
            }
        });

        int result = 0;
        bool sawTerminalResult = false;
        for (;;)
        {
            SessionWire::Frame frame;
            hr = SessionWire::ReadFrame(pipe.get(), frame);
            if (FAILED(hr))
            {
                break;
            }

            switch (frame.type)
            {
            case SessionWire::MessageType::Data:
            {
                DWORD written = 0;
                if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), frame.payload.data(), static_cast<DWORD>(frame.payload.size()), &written, nullptr))
                {
                    stop = true;
                }
                break;
            }
            case SessionWire::MessageType::Exit:
            {
                Json::Value exit;
                if (SUCCEEDED(SessionWire::ParseJsonPayload(frame.payload, exit)) && exit["has_exit_code"].asBool())
                {
                    result = exit["exit_code"].asInt();
                }
                sawTerminalResult = true;
                stop = true;
                goto done;
            }
            case SessionWire::MessageType::Error:
            {
                Json::Value error;
                if (SUCCEEDED(SessionWire::ParseJsonPayload(frame.payload, error)))
                {
                    fprintf(stderr, "[wtcli] session attach failed: %s\n", error["message"].asString().c_str());
                }
                result = 1;
                sawTerminalResult = true;
                stop = true;
                goto done;
            }
            default:
                break;
            }
        }

        if (!detachSent.load() && !sawTerminalResult)
        {
            fprintf(stderr,
                    "[wtcli] session attach failed: %s (0x%08X)\n",
                    AttachStreamFailureMessage(hr).c_str(),
                    static_cast<uint32_t>(hr));
            result = 1;
        }

    done:
        stop = true;
        CancelSynchronousIo(inputThread.native_handle());
        if (inputThread.joinable())
        {
            inputThread.join();
        }
        if (resizeThread.joinable())
        {
            resizeThread.join();
        }
        return result;
    }
}

// ── Main ──

// `wmain` — deliberately NOT `main`. Almost every string this tool forwards to
// the terminal arrives as an argument: `new-tab -d` starting directories,
// `-n` tab titles, `-c` command lines, `send-keys` payloads and the JSON blobs
// of `publish` / `send-event`. All of them may hold non-ASCII text.
//
// The CRT's narrow `__argv` is transcoded from the real UTF-16 command line
// through the *process ANSI code page*, so anything outside that code page is
// destroyed before we ever see it — on ACP 936 `D:\Obsidian\我的笔记` turns
// into GBK bytes that `Bstr()` below then decodes as UTF-8 (mojibake), and on
// a Latin ACP it degrades to literal `?`. Either way `CreateProcessW` on the
// terminal side fails the starting directory with 0x8007010b ERROR_DIRECTORY
// (GH#641), and titles / keystrokes / JSON silently lose characters.
//
// Taking `wchar_t**` keeps the original UTF-16 and lets CLI11's wide `parse`
// overload narrow it with `codecvt_utf8_utf16`, so every `std::string` bound
// to an option really is UTF-8 — which is exactly what `Bstr()` and
// `winrt::to_hstring` already assume.
int wmain(int argc, wchar_t** argv)
{
    winrt::init_apartment(winrt::apartment_type::multi_threaded);

    CLI::App app{ "wtcli - Windows Terminal CLI" };
    app.require_subcommand(0, 1);

    bool jsonMode = false;
    bool skipAuthenticate = false;
    int exitCode = 0;
    app.add_flag("--json", jsonMode, "Output raw JSON");
    app.add_flag("--skip-authenticate", skipAuthenticate, "Skip the compatibility handshake (testing only)");

    auto connect = [&]() -> winrt::com_ptr<ITerminalProtocol> {
        auto server = ConnectToTerminal(nullptr, nullptr, skipAuthenticate);
        if (!server)
            exitCode = 1;
        return server;
    };

    const auto currentUserSid = PersistentSessions::CurrentUserSidUtf8();

    auto printSessionHostSelectionError = [&](const HRESULT hr, const std::optional<uint32_t> desktopSession) {
        if (hr == HRESULT_FROM_WIN32(ERROR_MORE_DATA))
        {
            fprintf(stderr, "[wtcli] Multiple eligible interactive session hosts are available for this user. Re-run with --desktop-session <id>.\n");
            for (const auto& host : PersistentSessions::DiscoverHostsForCurrentUser(currentUserSid))
            {
                fprintf(stderr, "  desktop session %lu\n", static_cast<unsigned long>(host.desktopSessionId));
            }
            return;
        }

        if (desktopSession.has_value())
        {
            fprintf(stderr,
                    "[wtcli] No session host was found for desktop session %u. Log on interactively to that session and run 'wtcli session host'.\n",
                    desktopSession.value());
        }
        else
        {
            fprintf(stderr, "[wtcli] No session host was found. Log on interactively and run 'wtcli session host'.\n");
        }
    };

    auto printSessionRelayFailure = [&](const PersistentSessions::HostRecord& host, const HRESULT hr) {
        if (hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED))
        {
            fprintf(stderr,
                    "[wtcli] Persistent-session relay route to desktop session %lu was denied access. Ensure 'wtcli session host' is running as the same user.\n",
                    static_cast<unsigned long>(host.desktopSessionId));
            return;
        }

        if (hr == HRESULT_FROM_WIN32(ERROR_PIPE_BUSY))
        {
            fprintf(stderr,
                    "[wtcli] Persistent-session relay route to desktop session %lu is busy handling another control request. Retry the command.\n",
                    static_cast<unsigned long>(host.desktopSessionId));
            return;
        }

        if (PersistentSessions::IsStaleHostTransportError(hr))
        {
            fprintf(stderr,
                    "[wtcli] Persistent-session relay route to desktop session %lu found a stale host endpoint. Restart 'wtcli session host' in that interactive session.\n",
                    static_cast<unsigned long>(host.desktopSessionId));
            return;
        }

        fprintf(stderr,
                "[wtcli] Persistent-session relay route to desktop session %lu failed: %s (0x%08X)\n",
                static_cast<unsigned long>(host.desktopSessionId),
                PersistentSessions::HResultMessage(hr).c_str(),
                static_cast<uint32_t>(hr));
    };

    auto executeSessionControl = [&](const Json::Value& request, const std::optional<uint32_t> desktopSession, Json::Value& response) -> bool {
        const auto currentSessionId = CurrentProcessSessionId();
        const auto canActivateBrandedServerDirectly = IsCurrentProcessInteractiveDesktop();

        wtcli::SessionRouteContext routeContext{
            .currentSessionId = currentSessionId,
            .targetDesktopSession = desktopSession,
            .canActivateBrandedServerDirectly = canActivateBrandedServerDirectly,
        };

        if (wtcli::ShouldProbeDirectConnection(routeContext))
        {
            auto directServer = ConnectToTerminalForSessionHost(
                nullptr,
                nullptr,
                skipAuthenticate,
                true,
                false,
                canActivateBrandedServerDirectly);
            routeContext.hasDirectConnectionCapability = directServer != nullptr;
        }

        const auto decision = wtcli::ClassifySessionRoute(routeContext);

        if (decision.route == wtcli::SessionRoute::Direct)
        {
            const auto hr = PersistentSessions::HandleControlRequest(
                request,
                response,
                skipAuthenticate,
                canActivateBrandedServerDirectly);
            if (FAILED(hr))
            {
                fprintf(stderr, "[wtcli] Persistent-session direct route failed: %s (0x%08X)\n", PersistentSessions::HResultMessage(hr).c_str(), static_cast<uint32_t>(hr));
                exitCode = 1;
                return false;
            }
            return true;
        }

        PersistentSessions::HostRecord host;
        const auto resolveHr = PersistentSessions::ResolveHost(desktopSession, currentUserSid, host);
        if (FAILED(resolveHr))
        {
            printSessionHostSelectionError(resolveHr, desktopSession);
            exitCode = 1;
            return false;
        }

        const auto hr = PersistentSessions::SendControlRequest(host, request, response);
        if (FAILED(hr))
        {
            printSessionRelayFailure(host, hr);
            exitCode = 1;
            return false;
        }

        PersistentSessions::AddHostMetadata(host, response);
        return true;
    };

    std::optional<uint32_t> sessionCreateDesktop;
    std::optional<uint32_t> sessionListDesktop;
    std::optional<uint32_t> sessionInspectDesktop;
    std::optional<uint32_t> sessionAttachDesktop;
    std::optional<uint32_t> sessionKillDesktop;
    std::string sessionCreateName;
    std::string sessionCreateCommand;
    std::string sessionCreateCwd;
    std::string sessionCreateProfile;
    std::string sessionCreateTitle;
    std::string sessionInspectTarget;
    std::string sessionAttachTarget;
    std::string sessionKillTarget;

    auto* sessionCmd = app.add_subcommand("session", "Persistent reconnectable session commands with direct interactive routing and relay fallback");
    sessionCmd->require_subcommand(1);

    auto* sessionHostCmd = sessionCmd->add_subcommand("host", "Run the per-user persistent-session host for noninteractive relay routing");
    sessionHostCmd->callback([&]() {
        exitCode = PersistentSessions::RunSessionHost(jsonMode);
    });

    auto* sessionCreateCmd = sessionCmd->add_subcommand("create", "Create a persistent reconnectable session in the current or selected desktop session");
    sessionCreateCmd->add_option("--desktop-session", sessionCreateDesktop, "Target interactive desktop session ID when routing through a session host");
    sessionCreateCmd->add_option("--name", sessionCreateName, "Persistent session name");
    sessionCreateCmd->add_option("-c,--command", sessionCreateCommand, "Command to run");
    sessionCreateCmd->add_option("-d,--cwd", sessionCreateCwd, "Starting directory");
    sessionCreateCmd->add_option("-p,--profile", sessionCreateProfile, "Profile");
    sessionCreateCmd->add_option("--title", sessionCreateTitle, "Tab title");
    sessionCreateCmd->callback([&]() {
        Json::Value request;
        request["command"] = "create";
        request["name"] = sessionCreateName;
        request["commandline"] = sessionCreateCommand;
        request["cwd"] = sessionCreateCwd;
        request["profile"] = sessionCreateProfile;
        request["title"] = sessionCreateTitle;

        Json::Value response;
        if (!executeSessionControl(request, sessionCreateDesktop, response))
            return;
        if (jsonMode)
            PrintJson(response);
        else
            FormatPersistentSessionHuman(response);
    });

    auto* sessionListCmd = sessionCmd->add_subcommand("list", "List persistent reconnectable sessions from the current or selected desktop session");
    sessionListCmd->add_option("--desktop-session", sessionListDesktop, "Target interactive desktop session ID when multiple session hosts exist");
    sessionListCmd->callback([&]() {
        Json::Value request;
        request["command"] = "list";
        Json::Value response;
        if (!executeSessionControl(request, sessionListDesktop, response))
            return;
        if (jsonMode)
            PrintJson(response);
        else
            FormatPersistentSessionsHuman(response);
    });

    auto* sessionInspectCmd = sessionCmd->add_subcommand("inspect", "Inspect one persistent reconnectable session from the current or selected desktop session");
    sessionInspectCmd->add_option("target", sessionInspectTarget, "Persistent session ID or name")->required();
    sessionInspectCmd->add_option("--desktop-session", sessionInspectDesktop, "Target interactive desktop session ID when multiple session hosts exist");
    sessionInspectCmd->callback([&]() {
        Json::Value request;
        request["command"] = "inspect";
        request["target"] = sessionInspectTarget;
        Json::Value response;
        if (!executeSessionControl(request, sessionInspectDesktop, response))
            return;
        if (jsonMode)
            PrintJson(response);
        else
            FormatPersistentSessionHuman(response);
    });

    auto* sessionAttachCmd = sessionCmd->add_subcommand("attach", "Attach stdin/stdout to a persistent reconnectable session from the current or selected desktop session");
    sessionAttachCmd->add_option("target", sessionAttachTarget, "Persistent session ID or name")->required();
    sessionAttachCmd->add_option("--desktop-session", sessionAttachDesktop, "Target interactive desktop session ID when multiple session hosts exist");
    sessionAttachCmd->callback([&]() {
        Json::Value request;
        request["command"] = "attach";
        request["target"] = sessionAttachTarget;
        Json::Value response;
        if (!executeSessionControl(request, sessionAttachDesktop, response))
            return;
        exitCode = PersistentSessions::RunAttachClient(response);
    });

    auto* sessionKillCmd = sessionCmd->add_subcommand("kill", "Kill a persistent reconnectable session from the current or selected desktop session");
    sessionKillCmd->add_option("target", sessionKillTarget, "Persistent session ID or name")->required();
    sessionKillCmd->add_option("--desktop-session", sessionKillDesktop, "Target interactive desktop session ID when multiple session hosts exist");
    sessionKillCmd->callback([&]() {
        Json::Value request;
        request["command"] = "kill";
        request["target"] = sessionKillTarget;
        Json::Value response;
        if (!executeSessionControl(request, sessionKillDesktop, response))
            return;
        if (jsonMode)
            PrintJson(response);
        else
            printf("Session %s closed.\n", response["session_id"].asString().c_str());
    });

    // ── list-windows ──
    auto* listWindowsCmd = app.add_subcommand("list-windows", "List all windows")->alias("lsw");
    listWindowsCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        Json::Value windows;
        auto hr = CallJson([&](BSTR* j) { return server->ListWindows(j); }, windows);
        if (FAILED(hr))
        {
            fprintf(stderr, "ListWindows failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value arr(Json::objectValue);
            arr["windows"] = windows;
            PrintJson(arr);
        }
        else
        {
            FormatWindowsHuman(windows);
        }
    });

    // ── list-tabs ──
    std::string listTabsWindowId;
    auto* listTabsCmd = app.add_subcommand("list-tabs", "List tabs in a window")->alias("lst");
    listTabsCmd->add_option("-w,--window-id", listTabsWindowId, "Window ID");
    listTabsCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        uint64_t wid = 0;
        if (listTabsWindowId.empty())
        {
            wid = GetFirstWindowId(server.get());
            if (wid == 0)
            {
                // 0 is the server's "no filter" sentinel, not a real window id;
                // bail rather than silently listing tabs for ALL windows.
                fprintf(stderr, "[wtcli] Could not resolve a window (no windows or ListWindows failed)\n");
                exitCode = 1;
                return;
            }
        }
        else if (!TryParseU64(listTabsWindowId, wid))
        {
            fprintf(stderr, "[wtcli] Invalid --window-id: %s\n", listTabsWindowId.c_str());
            exitCode = 1;
            return;
        }
        Json::Value tabs;
        auto hr = CallJson([&](BSTR* j) { return server->ListTabs(wid, j); }, tabs);
        if (FAILED(hr))
        {
            fprintf(stderr, "ListTabs failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value arr(Json::objectValue);
            arr["tabs"] = tabs;
            PrintJson(arr);
        }
        else
        {
            FormatTabsHuman(tabs);
        }
    });

    // ── list-panes ──
    std::string listPanesTabId, listPanesWindowId;
    auto* listPanesCmd = app.add_subcommand("list-panes", "List panes in a tab")->alias("lsp");
    listPanesCmd->add_option("-t,--tab-id", listPanesTabId, "Tab ID");
    listPanesCmd->add_option("-w,--window-id", listPanesWindowId, "Window ID");
    listPanesCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        uint64_t wid = 0;
        if (!listPanesWindowId.empty() && !TryParseU64(listPanesWindowId, wid))
        {
            fprintf(stderr, "[wtcli] Invalid --window-id: %s\n", listPanesWindowId.c_str());
            exitCode = 1;
            return;
        }
        uint32_t tid = UINT32_MAX;
        if (!listPanesTabId.empty())
        {
            uint64_t t = 0;
            if (!TryParseU64(listPanesTabId, t) || t > UINT32_MAX)
            {
                fprintf(stderr, "[wtcli] Invalid --tab-id: %s\n", listPanesTabId.c_str());
                exitCode = 1;
                return;
            }
            tid = static_cast<uint32_t>(t);
        }
        if (tid == UINT32_MAX)
        {
            if (wid == 0)
            {
                wid = GetFirstWindowId(server.get());
                if (wid == 0)
                {
                    fprintf(stderr, "[wtcli] Could not resolve a window (no windows or ListWindows failed)\n");
                    exitCode = 1;
                    return;
                }
            }
            tid = GetFirstTabId(server.get(), wid);
            if (tid == UINT32_MAX)
            {
                fprintf(stderr, "[wtcli] Could not resolve a tab (no tabs or ListTabs failed)\n");
                exitCode = 1;
                return;
            }
        }
        Json::Value panes;
        auto hr = CallJson([&](BSTR* j) { return server->ListPanes(wid, tid, j); }, panes);
        if (FAILED(hr))
        {
            fprintf(stderr, "ListPanes failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value arr(Json::objectValue);
            arr["panes"] = panes;
            PrintJson(arr);
        }
        else
        {
            FormatPanesHuman(panes);
        }
    });

    // ── get-settings ──
    auto* getSettingsCmd = app.add_subcommand("get-settings", "Read the current Terminal settings");
    getSettingsCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        Json::Value settings;
        const auto hr = CallJson([&](BSTR* j) { return server->GetSettings(j); }, settings);
        if (FAILED(hr))
        {
            fprintf(stderr, "GetSettings failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        PrintJson(settings);
    });

    // ── active-pane ──
    auto* activePaneCmd = app.add_subcommand("active-pane", "Show the currently active pane");
    activePaneCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        Json::Value info;
        auto hr = CallJson([&](BSTR* j) { return server->GetActivePane(j); }, info);
        if (FAILED(hr))
        {
            fprintf(stderr, "GetActivePane failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
            PrintJson(info);
        else
            FormatActivePaneHuman(info);
    });

    // ── capture-pane ──
    std::string capturePaneTarget;
    int captureMaxLines = 200;
    bool captureLastPrompt = false;
    auto* capturePaneCmd = app.add_subcommand("capture-pane", "Capture pane output")->alias("capturep");
    capturePaneCmd->add_option("-t,--target", capturePaneTarget, "Session ID (GUID)");
    capturePaneCmd->add_option("-l,--max-lines", captureMaxLines, "Max lines");
    capturePaneCmd->add_flag("--last-prompt", captureLastPrompt, "Only return the most recent completed shell prompt (command + output, requires OSC 133 shell integration)");
    capturePaneCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), capturePaneTarget);
        wil::unique_bstr src{ Bstr(captureLastPrompt ? "last_prompt" : "scrollback") };
        Json::Value output;
        auto hr = CallJson([&](BSTR* j) { return server->ReadPaneOutput(sessionId, src.get(), captureMaxLines, j); }, output);
        if (FAILED(hr))
        {
            fprintf(stderr, "ReadPaneOutput failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
            PrintJson(output);
        else
            printf("%s\n", output["content"].asString().c_str());
    });

    // ── get-pane-context ──
    std::string paneContextTarget;
    int paneContextMaxLines = 30;
    int paneContextMaxCharacters = 4000;
    auto* paneContextCmd = app.add_subcommand("get-pane-context", "Resolve a pane and capture bounded context (requires the authentication handshake)");
    auto* paneContextTargetOption = paneContextCmd->add_option("-t,--target", paneContextTarget, "Explicit source pane session ID (GUID)");
    paneContextCmd->add_option("-l,--max-lines", paneContextMaxLines, "Maximum content lines for marked commands or buffer tails");
    paneContextCmd->add_option("--max-chars", paneContextMaxCharacters, "Maximum returned content characters");
    paneContextCmd->callback([&]() {
        constexpr int MaxContextLines = 1000;
        constexpr int MaxContextCharacters = 100000;
        if (paneContextMaxLines < 0 || paneContextMaxLines > MaxContextLines)
        {
            fprintf(stderr, "[wtcli] --max-lines must be between 0 and %d\n", MaxContextLines);
            exitCode = 1;
            return;
        }
        if (paneContextMaxCharacters < 0 || paneContextMaxCharacters > MaxContextCharacters)
        {
            fprintf(stderr, "[wtcli] --max-chars must be between 0 and %d\n", MaxContextCharacters);
            exitCode = 1;
            return;
        }

        GUID source{};
        const auto hasExplicitSource = paneContextTargetOption->count() != 0;
        if (hasExplicitSource)
        {
            source = GuidFromString(paneContextTarget, true);
            if (InlineIsEqualGUID(source, GUID{}))
            {
                fprintf(stderr, "[wtcli] Invalid session ID: %s\n", paneContextTarget.empty() ? "(empty)" : paneContextTarget.c_str());
                exitCode = 1;
                return;
            }
        }

        if (skipAuthenticate)
        {
            fprintf(stderr, "[wtcli] get-pane-context requires protocol negotiation; --skip-authenticate is not supported\n");
            exitCode = 1;
            return;
        }

        std::string version;
        auto server = ConnectToTerminal(nullptr, &version, skipAuthenticate, false, true);
        if (!server)
        {
            exitCode = 1;
            return;
        }

        auto support = ProtocolAtLeast(version, 2, 3);
        if (FAILED(support))
        {
            fprintf(stderr, "[wtcli] Invalid protocol version (server contract error)\n");
            exitCode = 1;
            return;
        }
        if (support == S_OK)
        {
            support = SupportsCapability(server.get(), "get_pane_context");
            if (FAILED(support))
            {
                fprintf(stderr, "[wtcli] GetCapabilities failed or returned malformed capabilities: 0x%08X\n", static_cast<uint32_t>(support));
                exitCode = 1;
                return;
            }
        }
        if (support == S_FALSE)
        {
            fprintf(stderr,
                    "[wtcli] WT_PROTOCOL_UNSUPPORTED_PANE_CONTEXT server=%s required=2.3\n",
                    version.empty() ? "unknown" : version.c_str());
            exitCode = 2;
            return;
        }

        Json::Value context;
        const auto hr = CallJson([&](BSTR* json) {
            return server->GetPaneContext(
                source,
                hasExplicitSource,
                paneContextMaxLines,
                paneContextMaxCharacters,
                json);
        },
                                 context);
        if (FAILED(hr))
        {
            fprintf(stderr, "GetPaneContext failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }

        if (jsonMode)
        {
            PrintJson(context);
        }
        else
        {
            printf("%s\n", context["content"].asString().c_str());
        }
    });

    // ── pane-status ──
    std::string paneStatusTarget;
    auto* paneStatusCmd = app.add_subcommand("pane-status", "Show pane process status");
    paneStatusCmd->add_option("-t,--target", paneStatusTarget, "Session ID (GUID)");
    paneStatusCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), paneStatusTarget);
        Json::Value status;
        auto hr = CallJson([&](BSTR* j) { return server->GetProcessStatus(sessionId, j); }, status);
        if (FAILED(hr))
        {
            fprintf(stderr, "GetProcessStatus failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
            PrintJson(status);
        else
            FormatPaneStatusHuman(status);
    });

    // ── new-tab ──
    std::string newTabCommand, newTabTitle, newTabCwd, newTabProfile;
    auto* newTabCmd = app.add_subcommand("new-tab", "Create a new tab")->alias("neww");
    newTabCmd->add_option("-c,--command", newTabCommand, "Command to run");
    newTabCmd->add_option("-n,--title", newTabTitle, "Tab title");
    newTabCmd->add_option("-d,--cwd", newTabCwd, "Starting directory");
    newTabCmd->add_option("-p,--profile", newTabProfile, "Profile");
    newTabCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        wil::unique_bstr profile{ Bstr(newTabProfile) }, command{ Bstr(newTabCommand) }, title{ Bstr(newTabTitle) }, cwd{ Bstr(newTabCwd) };
        Json::Value result;
        auto hr = CallJson([&](BSTR* j) {
            return server->CreateTab(0, profile.get(), command.get(), title.get(), cwd.get(), false, true, j);
        },
                           result);
        if (FAILED(hr))
        {
            fprintf(stderr, "CreateTab failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
            PrintJson(result);
        else
            FormatCreatedTabHuman(result);
    });

    // ── split-pane ──
    std::string splitPaneTarget, splitPaneCommand, splitPaneDirection, splitPaneProfile;
    bool splitHorizontal = false, splitVertical = false;
    double splitSize = 0.5;
    auto* splitPaneCmd = app.add_subcommand("split-pane", "Split a pane")->alias("splitw");
    splitPaneCmd->add_option("-t,--target", splitPaneTarget, "Session ID (GUID)");
    splitPaneCmd->add_option("-d,--direction", splitPaneDirection, "Split direction: right|left|up|down|auto");
    splitPaneCmd->add_flag("-H,--horizontal", splitHorizontal, "Split horizontally (legacy alias for --direction down)");
    splitPaneCmd->add_flag("-v,--vertical", splitVertical, "Split vertically (legacy alias for --direction right)");
    splitPaneCmd->add_option("-s,--size", splitSize, "Size fraction");
    splitPaneCmd->add_option("-c,--command", splitPaneCommand, "Command to run");
    splitPaneCmd->add_option("-p,--profile", splitPaneProfile, "Profile");
    splitPaneCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), splitPaneTarget);
        std::string dir;
        if (!splitPaneDirection.empty())
            dir = splitPaneDirection;
        else if (splitHorizontal)
            dir = "down";
        else if (splitVertical)
            dir = "right";
        else
            dir = "automatic";
        wil::unique_bstr dirB{ Bstr(dir) }, profile{ Bstr(splitPaneProfile) }, command{ Bstr(splitPaneCommand) };
        Json::Value result;
        auto hr = CallJson([&](BSTR* j) {
            return server->SplitPane(sessionId, dirB.get(), static_cast<float>(splitSize), profile.get(), command.get(), true, j);
        },
                           result);
        if (FAILED(hr))
        {
            fprintf(stderr, "SplitPane failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
            PrintJson(result);
        else
            FormatCreatedPaneHuman(result);
    });

    // ── kill-pane ──
    std::string killPaneTarget;
    auto* killPaneCmd = app.add_subcommand("kill-pane", "Close a pane")->alias("killp");
    killPaneCmd->add_option("-t,--target", killPaneTarget, "Session ID (GUID)");
    killPaneCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), killPaneTarget);
        auto hr = server->ClosePane(sessionId);
        if (FAILED(hr))
        {
            fprintf(stderr, "ClosePane failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value v;
            v["ok"] = true;
            v["session_id"] = GuidToString(sessionId);
            PrintJson(v);
        }
        else
        {
            printf("Session %s closed.\n", GuidToString(sessionId).c_str());
        }
    });

    // ── send-keys ──
    std::string sendKeysTarget;
    std::vector<std::string> sendKeysArgs;
    bool sendKeysRaw = false;
    auto* sendKeysCmd = app.add_subcommand("send-keys", "Send keys to a pane")->alias("send");
    sendKeysCmd->add_option("-t,--target", sendKeysTarget, "Session ID (GUID)");
    sendKeysCmd->add_flag("--raw", sendKeysRaw, "Treat the payload as literal UTF-8 text — skip tmux-style "
                                                "token translation (Enter/Tab/Escape/BSpace/C-x). Use this when "
                                                "forwarding arbitrary agent-supplied text.");
    sendKeysCmd->add_option("keys", sendKeysArgs, "Keys to send")->required();
    sendKeysCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), sendKeysTarget);
        auto text = sendKeysRaw ? wtcli::JoinAsUtf16(sendKeysArgs) : wtcli::TranslateKeys(sendKeysArgs);
        wil::unique_bstr textB{ SysAllocString(text.c_str()) };
        auto hr = server->SendInput(sessionId, textB.get());
        if (FAILED(hr))
        {
            fprintf(stderr, "SendInput failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value v;
            v["ok"] = true;
            v["session_id"] = GuidToString(sessionId);
            PrintJson(v);
        }
    });

    // ── focus-pane ──
    std::string focusPaneTarget;
    auto* focusPaneCmd = app.add_subcommand("focus-pane", "Switch focus to a pane")->alias("focusp");
    focusPaneCmd->add_option("-t,--target", focusPaneTarget, "Session ID (GUID)");
    focusPaneCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), focusPaneTarget);
        auto hr = server->FocusPane(sessionId);
        if (FAILED(hr))
        {
            fprintf(stderr, "FocusPane failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (jsonMode)
        {
            Json::Value v;
            v["ok"] = true;
            v["session_id"] = GuidToString(sessionId);
            PrintJson(v);
        }
        else
        {
            printf("Focused pane %s.\n", GuidToString(sessionId).c_str());
        }
    });

    // ── test-pipe ──
    auto* testPipeCmd = app.add_subcommand("test-pipe", "Test connection to Windows Terminal");
    testPipeCmd->callback([&]() {
        printf("Connecting to Windows Terminal...\n");
        auto server = connect();
        if (!server)
        {
            fprintf(stderr, "Connection failed.\n");
            return;
        }
        printf(skipAuthenticate ? "Connected without compatibility handshake!\n\n" : "Connected and authenticated!\n\n");

        Json::Value windows;
        if (SUCCEEDED(CallJson([&](BSTR* j) { return server->ListWindows(j); }, windows)))
        {
            Json::Value arr(Json::objectValue);
            arr["windows"] = windows;
            printf("list_windows:\n");
            PrintJson(arr);
        }
        printf("\n");

        Json::Value caps;
        if (SUCCEEDED(CallJson([&](BSTR* j) { return server->GetCapabilities(j); }, caps)))
        {
            printf("get_capabilities:\n");
            PrintJson(caps);
        }
    });

    // ── info ──
    auto* infoCmd = app.add_subcommand("info", "Show connection info");
    infoCmd->callback([&]() {
        wchar_t clsid[128]{};
        auto hasClsid = GetEnvironmentVariableW(L"WT_COM_CLSID", clsid, ARRAYSIZE(clsid)) > 0;

        std::string version;
        auto server = ConnectToTerminal(nullptr, &version, skipAuthenticate);

        Json::Value methods(Json::arrayValue);
        if (server)
        {
            CallJson([&](BSTR* j) { return server->GetCapabilities(j); }, methods);
        }

        if (jsonMode)
        {
            Json::Value v;
            if (hasClsid)
                v["com_clsid"] = winrt::to_string(winrt::hstring{ clsid });
            v["connected"] = (server != nullptr);
            if (!version.empty())
                v["protocol_version"] = version;
            v["methods"] = methods.isArray() ? methods : Json::Value(Json::arrayValue);
            PrintJson(v);
        }
        else
        {
            printf("Windows Terminal Protocol Info\n");
            printf("========================================\n");
            if (hasClsid)
                printf("  COM CLSID:  %ls\n", clsid);
            else
                printf("  COM CLSID:  (not set)\n");
            printf("\n");
            if (!server)
            {
                printf("  Connection: FAILED\n");
            }
            else
            {
                printf("  Connection: OK\n");
                if (!version.empty())
                    printf("  Protocol:   %s\n", version.c_str());
                printf("\n");
                if (methods.isArray() && methods.size() > 0)
                {
                    printf("  Methods:    %u supported\n", methods.size());
                    for (const auto& m : methods)
                        printf("              - %s\n", m.asString().c_str());
                }
            }
        }

        if (!server)
            exitCode = 1;
    });

    // ── wait-for ──
    std::string waitForTarget;
    int waitInterval = 500;
    int waitTimeout = 0;
    auto* waitForCmd = app.add_subcommand("wait-for", "Wait for a pane to exit");
    waitForCmd->add_option("-t,--target", waitForTarget, "Session ID (GUID)")->required();
    waitForCmd->add_option("--interval", waitInterval, "Poll interval (ms)");
    waitForCmd->add_option("--timeout", waitTimeout, "Timeout (seconds, 0=forever)");
    waitForCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        auto sessionId = ResolveSessionId(server.get(), waitForTarget);
        auto start = std::chrono::steady_clock::now();

        while (true)
        {
            Json::Value status;
            auto hr = CallJson([&](BSTR* j) { return server->GetProcessStatus(sessionId, j); }, status);
            if (FAILED(hr))
            {
                fprintf(stderr, "GetProcessStatus failed: 0x%08X\n", static_cast<uint32_t>(hr));
                exitCode = 1;
                return;
            }
            if (status["state"].asString() == "exited")
            {
                if (jsonMode)
                {
                    Json::Value v;
                    v["state"] = "exited";
                    if (status.isMember("exit_code"))
                        v["exit_code"] = status["exit_code"].asInt();
                    PrintJson(v);
                }
                else
                {
                    printf("Process exited");
                    if (status.isMember("has_exit_code") ? status["has_exit_code"].asBool() : status.isMember("exit_code"))
                        printf(" (code %d)", status["exit_code"].asInt());
                    printf("\n");
                }
                return;
            }

            if (waitTimeout > 0)
            {
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                                   std::chrono::steady_clock::now() - start)
                                   .count();
                if (elapsed >= waitTimeout)
                {
                    fprintf(stderr, "Timeout waiting for pane %s\n", waitForTarget.c_str());
                    exitCode = 1;
                    return;
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(waitInterval));
        }
    });

    // ── set-env ──
    std::string setEnvShell = "powershell";
    auto* setEnvCmd = app.add_subcommand("set-env", "Print env setup commands")->alias("setenv");
    setEnvCmd->add_option("-s,--shell", setEnvShell, "Shell: powershell, bash, cmd");
    setEnvCmd->callback([&]() {
        wchar_t clsid[128]{};
        GetEnvironmentVariableW(L"WT_COM_CLSID", clsid, ARRAYSIZE(clsid));
        auto cl = winrt::to_string(winrt::hstring{ clsid });

        if (setEnvShell == "powershell" || setEnvShell == "pwsh")
        {
            if (!cl.empty())
                printf("$env:WT_COM_CLSID = '%s'\n", cl.c_str());
        }
        else if (setEnvShell == "bash" || setEnvShell == "sh" || setEnvShell == "zsh")
        {
            if (!cl.empty())
                printf("export WT_COM_CLSID='%s'\n", cl.c_str());
        }
        else if (setEnvShell == "cmd")
        {
            if (!cl.empty())
                printf("set WT_COM_CLSID=%s\n", cl.c_str());
        }
    });

    // ── publish ──
    // Low-level "pass this JSON through to SendEvent verbatim" escape hatch.
    std::string publishJson;
    bool publishFromStdin = false;
    auto* publishCmd = app.add_subcommand("publish", "Forward raw JSON to SendEvent");
    auto* publishJsonOption = publishCmd->add_option("json", publishJson, "Full event JSON (e.g. {\"method\":\"autofix_state\",\"params\":{...}})");
    auto* publishStdinOption = publishCmd->add_flag("--stdin", publishFromStdin, "Read the full UTF-8 event JSON from stdin");
    publishJsonOption->excludes(publishStdinOption);
    publishCmd->require_option(1, 1);
    publishCmd->callback([&]() {
        if (publishFromStdin)
        {
            if (_setmode(_fileno(stdin), _O_BINARY) == -1)
            {
                fprintf(stderr, "[wtcli] publish: failed to configure stdin for binary input.\n");
                exitCode = 1;
                return;
            }
            std::string input;
            std::array<char, 8192> buffer;
            while (std::cin.read(buffer.data(), buffer.size()) || std::cin.gcount() > 0)
            {
                input.append(buffer.data(), static_cast<size_t>(std::cin.gcount()));
            }
            if (!std::cin.eof())
            {
                fprintf(stderr, "[wtcli] publish: failed to read JSON from stdin.\n");
                exitCode = 1;
                return;
            }
            publishJson = std::move(input);
        }
        if (publishJson.empty())
        {
            fprintf(stderr, "[wtcli] publish: JSON input must not be empty.\n");
            exitCode = 1;
            return;
        }
        auto server = connect();
        if (!server)
            return;
        wil::unique_bstr evt{ Bstr(publishJson) };
        auto hr = server->SendEvent(evt.get());
        if (FAILED(hr))
        {
            fprintf(stderr, "publish failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
        }
    });

    // ── send-event ──
    //
    // Also the transport every hook bundle installed before the native
    // `agent-hook` bridge still uses. Those bundles live in each CLI's own
    // plugin cache, which a Terminal upgrade never rewrites and whose
    // auto-refresh can fail outright, so they keep calling this subcommand
    // indefinitely. Removing it as superseded would silently stop tracking
    // every user whose hooks never refreshed.
    // Guarded by Feature.LegacyHookBundle.Tests.ps1 (C270).
    std::string sendEventType, sendEventJson, sendEventPaneTarget;
    auto* sendEventCmd = app.add_subcommand("send-event", "Publish an event to all listeners")->alias("se");
    sendEventCmd->add_option("-p,--pane", sendEventPaneTarget, "Source session ID (GUID); omit when the source pane is unknown");
    sendEventCmd->add_option("-e,--event", sendEventType, "Event type (e.g. agent.task.started)")->required();
    sendEventCmd->add_option("json", sendEventJson, "Event params as JSON object");
    sendEventCmd->callback([&]() {
        auto server = connect();
        if (!server)
            return;
        // No `--pane` publishes an empty `pane_id`, meaning "this event has no
        // known source pane". It deliberately does NOT fall back to the focused
        // pane: the callers that omit `--pane` are hook bridges whose process
        // never inherited WT_SESSION, and the focused pane is simply wherever
        // the user happens to be looking, so attributing to it is wrong in a
        // way that corrupts state rather than merely losing it. A legacy bundle
        // firing `agent.session.start` would evict the focused pane's real
        // session (the orphan-handover branch in agent_sessions.rs demotes the
        // previous owner of a reused pane to Ended) and rebind the pane to an
        // agent that was never in it, so Enter in the session list then focuses
        // a stranger's pane. Empty is the case WTA already models: `pane_known`
        // is false, so it skips the handover, leaves `active_by_pane` alone,
        // and routes by cli_source instead.
        Json::Value evt;
        if (!wtcli::BuildSendEventJson(sendEventType, sendEventJson, sendEventPaneTarget, evt))
        {
            fprintf(stderr, "Invalid JSON for --json: value must be a JSON object (e.g. '{\"key\":\"val\"}')\n");
            exitCode = 1;
            return;
        }
        Json::StreamWriterBuilder wb;
        wb["indentation"] = "";
        wil::unique_bstr evtB{ Bstr(Json::writeString(wb, evt)) };
        auto hr = server->SendEvent(evtB.get());
        if (FAILED(hr))
        {
            fprintf(stderr, "SendEvent failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
        }
    });

    // ── agent-hook ──
    // Native hook bridge. It deliberately never writes to stdout/stderr and
    // never returns a failure because hook failures can block agent actions.
    std::string agentHookEventType, agentHookCliSource;
    auto* agentHookCmd = app.add_subcommand("agent-hook", "Forward an agent lifecycle hook from stdin");
    agentHookCmd->add_option("-e,--event", agentHookEventType, "WTA agent event type")->required();
    agentHookCmd->add_option("-c,--cli-source", agentHookCliSource, "Source agent CLI")->required();
    agentHookCmd->callback([&]() {
        try
        {
            // A shell-pane session always has both values. The shared ACP
            // process has no pane identity and is already tracked over ACP, so
            // dropping it here also prevents events from binding to the active
            // user pane.
            const auto paneGuid = GuidFromString(EnvironmentValue(L"WT_SESSION"), true);
            if (EnvironmentValue(L"WT_COM_CLSID").empty() || IsEqualGUID(paneGuid, GUID{}))
            {
                return;
            }
            const auto paneId = GuidToString(paneGuid);

            // Read a bounded amount. `BuildAgentHookEventJson` caps what goes
            // on the wire, but that happens *after* the whole of stdin is in
            // memory and parsed, so an oversized hook payload still costs
            // memory and parse time first. The ceiling is deliberately far
            // above the event budget rather than equal to it: payloads larger
            // than the budget are normal and still produce a useful event
            // (truncated body, routing fields intact), so capping at the
            // budget would drop events that work today.
            constexpr std::streamsize kMaxHookStdinChars = 1024 * 1024;
            std::string input(static_cast<size_t>(kMaxHookStdinChars) + 1, '\0');
            std::cin.read(input.data(), static_cast<std::streamsize>(input.size()));
            const auto readChars = std::cin.gcount();
            if (readChars > kMaxHookStdinChars)
            {
                // Anything this large is a broken or hostile producer, not a
                // hook. Drop it rather than parse it; the callback still exits
                // 0 so a fail-closed CLI is unaffected.
                return;
            }
            input.resize(static_cast<size_t>(readChars));

            Json::Value event;
            if (!wtcli::BuildAgentHookEventJson(
                    agentHookEventType,
                    agentHookCliSource,
                    input,
                    paneId,
                    AgentSessionIdFromEnvironment(agentHookCliSource),
                    event))
            {
                return;
            }

            auto server = ConnectToTerminal(nullptr, nullptr, skipAuthenticate, true);
            if (!server)
            {
                return;
            }

            Json::StreamWriterBuilder writer;
            writer["indentation"] = "";
            wil::unique_bstr eventJson{ Bstr(Json::writeString(writer, event)) };
            if (eventJson)
            {
                server->SendEvent(eventJson.get());
            }
        }
        catch (...)
        {
            // Session tracking must never affect the parent agent CLI.
        }
    });

    // ── listen ──
    std::string listenTarget;
    std::string listenEventFilter;
    std::string listenReadyToken;
    DWORD listenParentPid = 0;
    auto* listenCmd = app.add_subcommand("listen", "Stream real-time events from Windows Terminal");
    listenCmd->add_option("-t,--target", listenTarget, "Filter by session ID (GUID)");
    listenCmd->add_option("--event", listenEventFilter, "Filter by event type (supports trailing wildcard, e.g. agent.*)");
    listenCmd->add_option("--parent-pid", listenParentPid, "Exit when the specified parent process exits");
    listenCmd->add_option("--ready-token", listenReadyToken, "Emit an internal JSON readiness marker after Subscribe succeeds");
    listenCmd->callback([&]() {
        wil::unique_handle parentProcess;
        if (listenParentPid != 0)
        {
            parentProcess.reset(OpenProcess(SYNCHRONIZE, FALSE, listenParentPid));
            if (!parentProcess)
            {
                fprintf(stderr, "[wtcli] listen: failed to open parent process %lu (0x%08X)\n", listenParentPid, GetLastError());
                exitCode = 1;
                return;
            }
        }

        auto server = connect();
        if (!server)
        {
            exitCode = 1;
            return;
        }

        static HANDLE s_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!s_stopEvent)
        {
            fprintf(stderr, "[wtcli] listen: failed to create stop event (0x%08X)\n", GetLastError());
            exitCode = 1;
            return;
        }
        SetConsoleCtrlHandler([](DWORD) -> BOOL {
            SetEvent(s_stopEvent);
            return TRUE;
        },
                              TRUE);

        if (!jsonMode)
            fprintf(stderr, "Listening for events... (Ctrl-C to stop)\n");

        // EventSink is born with _ref == 1, so attach() (adopt, no AddRef) hands
        // that reference to the com_ptr. RAII then Releases on every exit path --
        // exception-safe and robust against future early-returns, no manual
        // Release to forget.
        winrt::com_ptr<ITerminalProtocolEventSink> sink;
        sink.attach(new EventSink([&](const std::string& eventUtf8) {
            if (!wtcli::MatchesEventFilter(eventUtf8, listenTarget, listenEventFilter))
                return;
            printf("%s\n", eventUtf8.c_str());
            fflush(stdout);
        }));

        auto hr = server->Subscribe(sink.get());
        if (FAILED(hr))
        {
            fprintf(stderr, "Subscribe failed: 0x%08X\n", static_cast<uint32_t>(hr));
            exitCode = 1;
            return;
        }
        if (!listenReadyToken.empty())
        {
            Json::Value ready{ Json::objectValue };
            ready["_wtcli"] = "listener_ready";
            ready["token"] = listenReadyToken;
            Json::StreamWriterBuilder writer;
            writer["indentation"] = "";
            printf("%s\n", Json::writeString(writer, ready).c_str());
            fflush(stdout);
        }

        DWORD waitResult = WAIT_OBJECT_0;
        if (parentProcess)
        {
            const HANDLE waitHandles[]{ s_stopEvent, parentProcess.get() };
            waitResult = WaitForMultipleObjects(ARRAYSIZE(waitHandles), waitHandles, FALSE, INFINITE);
        }
        else
        {
            waitResult = WaitForSingleObject(s_stopEvent, INFINITE);
        }
        if (waitResult == WAIT_FAILED)
        {
            fprintf(stderr, "[wtcli] listen: wait failed (0x%08X)\n", GetLastError());
            exitCode = 1;
        }
        server->Unsubscribe();
        // s_stopEvent is intentionally NOT closed: it is static and still
        // referenced by the registered Ctrl-C handler (a non-capturing lambda
        // that can only reach it via the static), so closing it would leave the
        // handler pointing at an invalid handle. It is reclaimed at process exit.
    });

    // ── Default (no subcommand) ──
    app.callback([&]() {
        if (app.get_subcommands().empty())
        {
            printf("wtcli - Windows Terminal CLI\n\n");
            printf("Usage: wtcli [--json] <subcommand>\n\n");
            printf("Run 'wtcli --help' for available subcommands.\n");
        }
    });

    try
    {
        // CLI11's wide overload; see the comment on `wmain` above.
        app.parse(argc, argv);
    }
    catch (const CLI::ParseError& e)
    {
        return app.exit(e);
    }

    return exitCode;
}
