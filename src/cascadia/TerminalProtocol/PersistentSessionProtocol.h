// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include <json/json.h>
#include <sddl.h>
#include <wil/resource.h>
#include <wil/result.h>
#include <wil/token_helpers.h>

#include <array>
#include <cstring>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace Microsoft::Terminal::PersistentSession
{
    inline constexpr uint32_t WireMagic = 0x53545057; // "WTPS"
    inline constexpr uint16_t WireVersion = 1;
    inline constexpr uint32_t MaxFramePayloadBytes = 1024 * 1024;
    inline constexpr uint32_t MaxDataPayloadBytes = 256 * 1024;
    inline constexpr uint32_t MaxControlPayloadBytes = 64 * 1024;

    enum class MessageType : uint16_t
    {
        Hello = 1,
        Request = 2,
        Response = 3,
        Data = 4,
        Resize = 5,
        Detach = 6,
        Exit = 7,
        Error = 8,
    };

    struct FrameHeader
    {
        uint32_t magic;
        uint16_t version;
        uint16_t type;
        uint32_t payloadLength;
    };

    struct Frame
    {
        MessageType type{};
        std::vector<uint8_t> payload;
    };

    struct ResizePayload
    {
        uint32_t rows;
        uint32_t columns;
    };

    struct SecurityAttributesHolder
    {
        SECURITY_ATTRIBUTES attributes{};
        wil::unique_hlocal_security_descriptor descriptor;

        SECURITY_ATTRIBUTES* get() noexcept
        {
            return descriptor ? &attributes : nullptr;
        }
    };

    inline HRESULT ReadExact(const HANDLE handle, void* const buffer, const uint32_t bytes) noexcept
    {
        uint8_t* cursor = static_cast<uint8_t*>(buffer);
        uint32_t remaining = bytes;
        while (remaining > 0)
        {
            DWORD read = 0;
            if (!ReadFile(handle, cursor, remaining, &read, nullptr))
            {
                return HRESULT_FROM_WIN32(GetLastError());
            }
            if (read == 0)
            {
                return HRESULT_FROM_WIN32(ERROR_BROKEN_PIPE);
            }
            cursor += read;
            remaining -= read;
        }
        return S_OK;
    }

    inline HRESULT WriteExact(const HANDLE handle, const void* const buffer, const uint32_t bytes) noexcept
    {
        const uint8_t* cursor = static_cast<const uint8_t*>(buffer);
        uint32_t remaining = bytes;
        while (remaining > 0)
        {
            DWORD written = 0;
            if (!WriteFile(handle, cursor, remaining, &written, nullptr))
            {
                return HRESULT_FROM_WIN32(GetLastError());
            }
            if (written == 0)
            {
                return HRESULT_FROM_WIN32(ERROR_BROKEN_PIPE);
            }
            cursor += written;
            remaining -= written;
        }
        return S_OK;
    }

    inline HRESULT WriteFrame(const HANDLE handle, const MessageType type, const std::span<const uint8_t> payload) noexcept
    {
        RETURN_HR_IF(E_INVALIDARG, payload.size() > MaxFramePayloadBytes);
        FrameHeader header{
            .magic = WireMagic,
            .version = WireVersion,
            .type = static_cast<uint16_t>(type),
            .payloadLength = static_cast<uint32_t>(payload.size()),
        };
        RETURN_IF_FAILED(WriteExact(handle, &header, sizeof(header)));
        if (!payload.empty())
        {
            RETURN_IF_FAILED(WriteExact(handle, payload.data(), static_cast<uint32_t>(payload.size())));
        }
        return S_OK;
    }

    inline HRESULT ReadFrame(const HANDLE handle, Frame& frame) noexcept
    {
        FrameHeader header{};
        RETURN_IF_FAILED(ReadExact(handle, &header, sizeof(header)));
        RETURN_HR_IF(E_UNEXPECTED, header.magic != WireMagic);
        RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH), header.version != WireVersion);
        RETURN_HR_IF(E_UNEXPECTED, header.payloadLength > MaxFramePayloadBytes);

        frame.type = static_cast<MessageType>(header.type);
        frame.payload.resize(header.payloadLength);
        if (header.payloadLength > 0)
        {
            RETURN_IF_FAILED(ReadExact(handle, frame.payload.data(), header.payloadLength));
        }
        return S_OK;
    }

    inline HRESULT WriteJsonFrame(const HANDLE handle, const MessageType type, const Json::Value& payload) noexcept
    {
        Json::StreamWriterBuilder builder;
        builder["indentation"] = "";
        const auto json = Json::writeString(builder, payload);
        RETURN_HR_IF(E_INVALIDARG, json.size() > MaxControlPayloadBytes);
        const auto bytes = std::span<const uint8_t>{
            reinterpret_cast<const uint8_t*>(json.data()),
            json.size()
        };
        return WriteFrame(handle, type, bytes);
    }

    inline HRESULT ParseJsonPayload(const std::vector<uint8_t>& payload, Json::Value& json) noexcept
    {
        Json::CharReaderBuilder builder;
        std::string errors;
        std::string serialized{
            reinterpret_cast<const char*>(payload.data()),
            payload.size()
        };
        std::istringstream stream(serialized);
        return Json::parseFromStream(builder, stream, &json, &errors) ? S_OK : E_UNEXPECTED;
    }

    inline HRESULT ReadJsonFrame(const HANDLE handle, const MessageType expected, Json::Value& json) noexcept
    {
        Frame frame;
        RETURN_IF_FAILED(ReadFrame(handle, frame));
        RETURN_HR_IF(E_UNEXPECTED, frame.type != expected);
        return ParseJsonPayload(frame.payload, json);
    }

    inline HRESULT WriteHello(const HANDLE handle, const std::string_view role) noexcept
    {
        Json::Value hello;
        hello["role"] = std::string{ role };
        hello["version"] = WireVersion;
        return WriteJsonFrame(handle, MessageType::Hello, hello);
    }

    inline HRESULT ReadAndValidateHello(const HANDLE handle, const std::string_view expectedRole, Json::Value& hello) noexcept
    {
        RETURN_IF_FAILED(ReadJsonFrame(handle, MessageType::Hello, hello));
        RETURN_HR_IF(E_UNEXPECTED, !hello.isObject());
        RETURN_HR_IF(E_UNEXPECTED, !hello["role"].isString() || hello["role"].asString() != expectedRole);
        RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH), !hello["version"].isUInt() || hello["version"].asUInt() != WireVersion);
        return S_OK;
    }

    inline HRESULT WriteResizeFrame(const HANDLE handle, const uint32_t rows, const uint32_t columns) noexcept
    {
        const ResizePayload payload{ rows, columns };
        const auto bytes = std::span<const uint8_t>{
            reinterpret_cast<const uint8_t*>(&payload),
            sizeof(payload)
        };
        return WriteFrame(handle, MessageType::Resize, bytes);
    }

    inline HRESULT ParseResizePayload(const std::vector<uint8_t>& payload, ResizePayload& resize) noexcept
    {
        RETURN_HR_IF(E_UNEXPECTED, payload.size() != sizeof(ResizePayload));
        memcpy(&resize, payload.data(), sizeof(ResizePayload));
        return S_OK;
    }

    inline std::wstring CurrentUserSidString()
    {
        const auto tokenInfo = wil::get_token_information<TOKEN_USER>(GetCurrentProcessToken());
        wil::unique_hlocal_string sid;
        THROW_IF_WIN32_BOOL_FALSE(ConvertSidToStringSidW(tokenInfo->User.Sid, sid.put()));
        return sid.get();
    }

    inline SecurityAttributesHolder CreateUserAndSystemPipeSecurity()
    {
        SecurityAttributesHolder holder;
        const auto sid = CurrentUserSidString();
        const auto sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + sid + L")S:(ML;;NW;;;ME)";
        unsigned long descriptorSize = 0;
        THROW_IF_WIN32_BOOL_FALSE(ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.c_str(),
            SDDL_REVISION_1,
            wil::out_param_ptr<PSECURITY_DESCRIPTOR*>(holder.descriptor),
            &descriptorSize));
        holder.attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
        holder.attributes.lpSecurityDescriptor = holder.descriptor.get();
        holder.attributes.bInheritHandle = FALSE;
        return holder;
    }
}
