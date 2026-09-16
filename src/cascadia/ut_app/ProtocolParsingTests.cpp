// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "precomp.h"

#include "../TerminalProtocol/ProtocolParsing.h"
#include "../TerminalProtocol/PersistentSessionProtocol.h"
#include "../../tools/wtcli/wtcli_functions.h"
#include "../../types/inc/utils.hpp"

using namespace WEX::TestExecution;
using namespace Microsoft::Terminal::Protocol::Parsing;
namespace SessionWire = Microsoft::Terminal::PersistentSession;

namespace TerminalAppUnitTests
{
    class ProtocolParsingTests
    {
        TEST_CLASS(ProtocolParsingTests);

        TEST_METHOD(DefaultPasteRequestUsesDirectRoute);
        TEST_METHOD(AgentAvailabilityUsesDirectRoute);
        TEST_METHOD(AgentSessionsRetiredUsesDirectRoute);
        TEST_METHOD(RestartRequestIdentityIsStampedOnce);
        TEST_METHOD(BoundedCommandPreservesUtf8Characters);
        TEST_METHOD(BoundedBufferTailAppliesLineAndCharacterLimits);
        TEST_METHOD(BoundedBufferTailPreservesBlankLines);
        TEST_METHOD(CapabilitySupportDistinguishesUnsupportedFromMalformed);
        TEST_METHOD(PersistentSessionHelloRoundTrips);
        TEST_METHOD(PersistentSessionResizeFrameRoundTrips);
        TEST_METHOD(SessionRouteSelectionTests);
        TEST_METHOD(PersistentSessionHostDiscoveryParsingTests);
        TEST_METHOD(PersistentSessionHostSelectionAutoSelectsSameUserHost);
        TEST_METHOD(PersistentSessionHostSelectionRequiresExplicitDesktopSessionWhenAmbiguous);
        TEST_METHOD(PersistentSessionHostSelectionHonorsExplicitDesktopSession);
    };

    void ProtocolParsingTests::CapabilitySupportDistinguishesUnsupportedFromMalformed()
    {
        for (const auto* payload : { R"(["get_pane_context"])", R"(["other","get_pane_context"])" })
        {
            Json::Value capabilities;
            VERIFY_IS_TRUE(ParseJson(payload, capabilities));
            VERIFY_ARE_EQUAL(CapabilitySupport::Supported, ClassifyCapability(capabilities, "get_pane_context"));
        }
        for (const auto* payload : { "[]", R"(["other"])" })
        {
            Json::Value capabilities;
            VERIFY_IS_TRUE(ParseJson(payload, capabilities));
            VERIFY_ARE_EQUAL(CapabilitySupport::Unsupported, ClassifyCapability(capabilities, "get_pane_context"));
        }
        for (const auto* payload : { "null", "{}", "true", "1", R"("get_pane_context")", "[null]", R"(["get_pane_context",{}])", R"([false,"get_pane_context"])" })
        {
            Json::Value capabilities;
            VERIFY_IS_TRUE(ParseJson(payload, capabilities));
            VERIFY_ARE_EQUAL(CapabilitySupport::Invalid, ClassifyCapability(capabilities, "get_pane_context"));
        }
    }

    void ProtocolParsingTests::DefaultPasteRequestUsesDirectRoute()
    {
        Json::Value event;
        const auto route = ClassifySendEvent(
            R"({"type":"event","method":"request_default_paste","params":{"window_id":"1","tab_id":"tab-a","pane_id":"pane-a"}})",
            event);

        VERIFY_ARE_EQUAL(SendEventRoute::DefaultPaste, route);
        VERIFY_ARE_EQUAL("request_default_paste", event["method"].asString());
    }

    void ProtocolParsingTests::AgentAvailabilityUsesDirectRoute()
    {
        Json::Value event;
        const auto route = ClassifySendEvent(
            R"({"type":"event","method":"agent_availability_changed","params":{"agent_id":"copilot","tab_id":"tab-a"}})",
            event);

        VERIFY_ARE_EQUAL(SendEventRoute::AgentAvailability, route);
        VERIFY_ARE_EQUAL("copilot", event["params"]["agent_id"].asString());
    }

    void ProtocolParsingTests::AgentSessionsRetiredUsesDirectRoute()
    {
        Json::Value event;
        const auto route = ClassifySendEvent(
            R"({"type":"event","method":"agent_sessions_retired","params":{"operation_id":"123-1","success":true,"reason":"restart_agent_stack","failed_tabs":[]}})",
            event);

        VERIFY_ARE_EQUAL(SendEventRoute::AgentSessionsRetired, route);
        VERIFY_ARE_EQUAL("123-1", event["params"]["operation_id"].asString());
    }

    void ProtocolParsingTests::RestartRequestIdentityIsStampedOnce()
    {
        Json::Value event;
        VERIFY_IS_TRUE(ParseJson(
            R"({"type":"event","method":"restart_agent_stack","params":{}})",
            event));

        EnsureRequestId(event, "request-1");
        EnsureRequestId(event, "request-2");

        VERIFY_ARE_EQUAL("request-1", event["params"]["request_id"].asString());
    }

    void ProtocolParsingTests::BoundedCommandPreservesUtf8Characters()
    {
        const auto result = BuildBoundedCommand("a\xF0\x9F\x8D\xA6"
                                                "bc",
                                                1,
                                                3);
        VERIFY_ARE_EQUAL(std::string{ "a\xF0\x9F\x8D\xA6"
                                      "b" },
                         result.content);
        VERIFY_ARE_EQUAL(1, result.lineCount);
        VERIFY_IS_TRUE(result.truncated);

        const auto lines = BuildBoundedCommand("command\r\n"
                                               "first\r\n"
                                               "second\r\n",
                                               2,
                                               100);
        VERIFY_ARE_EQUAL("command\n"
                         "first",
                         lines.content);
        VERIFY_ARE_EQUAL(2, lines.lineCount);
        VERIFY_IS_TRUE(lines.truncated);

        const auto boundedLines = BuildBoundedCommand("command\r\n"
                                                      "first\r\n"
                                                      "second\r\n",
                                                      2,
                                                      10);
        VERIFY_ARE_EQUAL("command\n"
                         "fi",
                         boundedLines.content);
        VERIFY_ARE_EQUAL(2, boundedLines.lineCount);
        VERIFY_IS_TRUE(boundedLines.truncated);

        const auto boundedSingleLine = BuildBoundedCommand("command\r\n"
                                                           "first\r\n",
                                                           2,
                                                           5);
        VERIFY_ARE_EQUAL("comma", boundedSingleLine.content);
        VERIFY_ARE_EQUAL(1, boundedSingleLine.lineCount);
        VERIFY_IS_TRUE(boundedSingleLine.truncated);
    }

    void ProtocolParsingTests::BoundedBufferTailAppliesLineAndCharacterLimits()
    {
        const auto byLines = BuildBoundedBufferTail("first\r\n"
                                                    "second\r\n"
                                                    "third\r\n",
                                                    2,
                                                    100);
        VERIFY_ARE_EQUAL("second\n"
                         "third",
                         byLines.content);
        VERIFY_ARE_EQUAL(2, byLines.lineCount);
        VERIFY_IS_TRUE(byLines.truncated);

        const auto byCharacters = BuildBoundedBufferTail("one\r\n"
                                                         "two\r\n"
                                                         "three\r\n",
                                                         3,
                                                         6);
        VERIFY_ARE_EQUAL("\n"
                         "three",
                         byCharacters.content);
        VERIFY_ARE_EQUAL(2, byCharacters.lineCount);
        VERIFY_IS_TRUE(byCharacters.truncated);

        const auto exact = BuildBoundedBufferTail("one\r\n"
                                                  "two\r\n",
                                                  2,
                                                  7);
        VERIFY_ARE_EQUAL("one\n"
                         "two",
                         exact.content);
        VERIFY_ARE_EQUAL(2, exact.lineCount);
        VERIFY_IS_FALSE(exact.truncated);
    }

    void ProtocolParsingTests::BoundedBufferTailPreservesBlankLines()
    {
        const auto leading = BuildBoundedBufferTail("\r\n\r\n"
                                                    "error\r\n",
                                                    3,
                                                    100);
        VERIFY_ARE_EQUAL("\n\n"
                         "error",
                         leading.content);
        VERIFY_ARE_EQUAL(3, leading.lineCount);
        VERIFY_IS_FALSE(leading.truncated);

        const auto selectedTail = BuildBoundedBufferTail("older\r\n\r\n\r\n"
                                                         "error\r\n",
                                                         3,
                                                         100);
        VERIFY_ARE_EQUAL("\n\n"
                         "error",
                         selectedTail.content);
        VERIFY_ARE_EQUAL(3, selectedTail.lineCount);
        VERIFY_IS_TRUE(selectedTail.truncated);

        const auto interior = BuildBoundedBufferTail("first\r\n\r\n"
                                                     "error\r\n",
                                                     3,
                                                     100);
        VERIFY_ARE_EQUAL("first\n\n"
                         "error",
                         interior.content);
        VERIFY_ARE_EQUAL(3, interior.lineCount);
        VERIFY_IS_FALSE(interior.truncated);

        const auto trailing = BuildBoundedBufferTail("error\r\n\r\n", 3, 100);
        VERIFY_ARE_EQUAL("error\n", trailing.content);
        VERIFY_ARE_EQUAL(2, trailing.lineCount);
        VERIFY_IS_FALSE(trailing.truncated);

        const auto terminated = BuildBoundedBufferTail("error\r\n", 3, 100);
        VERIFY_ARE_EQUAL("error", terminated.content);
        VERIFY_ARE_EQUAL(1, terminated.lineCount);
        VERIFY_IS_FALSE(terminated.truncated);
    }

    void ProtocolParsingTests::PersistentSessionHelloRoundTrips()
    {
        auto pipe = ::Microsoft::Console::Utils::CreateOverlappedPipe(PIPE_ACCESS_DUPLEX, 4096);

        VERIFY_SUCCEEDED(SessionWire::WriteHello(pipe.client.get(), "client"));

        Json::Value hello;
        VERIFY_SUCCEEDED(SessionWire::ReadAndValidateHello(pipe.server.get(), "client", hello));
        VERIFY_ARE_EQUAL(std::string{ "client" }, hello["role"].asString());
        VERIFY_ARE_EQUAL(static_cast<unsigned>(SessionWire::WireVersion), hello["version"].asUInt());
    }

    void ProtocolParsingTests::PersistentSessionResizeFrameRoundTrips()
    {
        auto pipe = ::Microsoft::Console::Utils::CreateOverlappedPipe(PIPE_ACCESS_DUPLEX, 4096);

        VERIFY_SUCCEEDED(SessionWire::WriteResizeFrame(pipe.client.get(), 48, 132));

        SessionWire::Frame frame;
        VERIFY_SUCCEEDED(SessionWire::ReadFrame(pipe.server.get(), frame));
        VERIFY_ARE_EQUAL(static_cast<int>(SessionWire::MessageType::Resize), static_cast<int>(frame.type));

        SessionWire::ResizePayload resize{};
        VERIFY_SUCCEEDED(SessionWire::ParseResizePayload(frame.payload, resize));
        VERIFY_ARE_EQUAL(48u, resize.rows);
        VERIFY_ARE_EQUAL(132u, resize.columns);
    }

    void ProtocolParsingTests::SessionRouteSelectionTests()
    {
        // 1. Same interactive session with direct COM connection capability -> Direct
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 1,
                .targetDesktopSession = std::nullopt,
                .hasDirectConnectionCapability = true,
                .canActivateBrandedServerDirectly = true,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Direct), static_cast<int>(decision.route));
            VERIFY_IS_FALSE(decision.explanation.empty());
        }

        // 2. Same interactive session with explicit matching --desktop-session and direct capability -> Direct
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 2,
                .targetDesktopSession = 2,
                .hasDirectConnectionCapability = true,
                .canActivateBrandedServerDirectly = true,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Direct), static_cast<int>(decision.route));
        }

        // 3. Different desktop session targeted explicitly -> Relay
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 1,
                .targetDesktopSession = 2,
                .hasDirectConnectionCapability = true, // even if direct capability existed for local session
                .canActivateBrandedServerDirectly = true,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Relay), static_cast<int>(decision.route));
            VERIFY_IS_TRUE(decision.explanation.find("Target desktop session 2") != std::string::npos);
        }

        // 4. Session 0 / non-interactive context without direct capability -> Relay
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 0,
                .targetDesktopSession = std::nullopt,
                .hasDirectConnectionCapability = false,
                .canActivateBrandedServerDirectly = false,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Relay), static_cast<int>(decision.route));
            VERIFY_IS_TRUE(decision.explanation.find("Session 0") != std::string::npos);
        }

        // 5. Non-zero but non-interactive session without direct capability (e.g. headless SSH shell in session 1) -> Relay
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 1,
                .targetDesktopSession = std::nullopt,
                .hasDirectConnectionCapability = false,
                .canActivateBrandedServerDirectly = false,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Relay), static_cast<int>(decision.route));
            VERIFY_IS_TRUE(decision.explanation.find("interactive desktop") != std::string::npos);
        }

        // 6. Interactive session without a direct Terminal connection still relays
        {
            wtcli::SessionRouteContext ctx{
                .currentSessionId = 5,
                .targetDesktopSession = std::nullopt,
                .hasDirectConnectionCapability = false,
                .canActivateBrandedServerDirectly = true,
            };
            const auto decision = wtcli::ClassifySessionRoute(ctx);
            VERIFY_ARE_EQUAL(static_cast<int>(wtcli::SessionRoute::Relay), static_cast<int>(decision.route));
            VERIFY_IS_TRUE(decision.explanation.find("Direct Terminal COM connection unavailable") != std::string::npos);
        }
    }

    void ProtocolParsingTests::PersistentSessionHostDiscoveryParsingTests()
    {
        Json::Value valid;
        valid["desktop_session_id"] = 3u;
        valid["pid"] = 4321u;
        valid["pipe_name"] = R"(\\.\pipe\IntelligentTerminal.SessionHost.3.test)";
        valid["owner_sid"] = "S-1-5-21-1000";
        valid["generation"] = "generation";
        valid["instance_id"] = "instance";

        wtcli::PersistentSessionHostDiscoveryRecord record;
        VERIFY_IS_TRUE(wtcli::TryParsePersistentSessionHostDiscoveryRecord(valid, record));
        VERIFY_ARE_EQUAL(3u, record.desktopSessionId);
        VERIFY_ARE_EQUAL(4321u, record.pid);
        VERIFY_ARE_EQUAL(std::string{ R"(\\.\pipe\IntelligentTerminal.SessionHost.3.test)" }, record.pipeName);
        VERIFY_ARE_EQUAL(std::string{ "S-1-5-21-1000" }, record.ownerSid);

        Json::Value missingOwner = valid;
        missingOwner.removeMember("owner_sid");
        VERIFY_IS_FALSE(wtcli::TryParsePersistentSessionHostDiscoveryRecord(missingOwner, record));

        Json::Value emptyPipe = valid;
        emptyPipe["pipe_name"] = "";
        VERIFY_IS_FALSE(wtcli::TryParsePersistentSessionHostDiscoveryRecord(emptyPipe, record));
    }

    void ProtocolParsingTests::PersistentSessionHostSelectionAutoSelectsSameUserHost()
    {
        const std::vector<wtcli::PersistentSessionHostDiscoveryRecord> records{
            {
                .desktopSessionId = 4,
                .pid = 100u,
                .pipeName = "pipe-a",
                .ownerSid = "S-1-5-21-SELF",
            },
            {
                .desktopSessionId = 9,
                .pid = 200u,
                .pipeName = "pipe-b",
                .ownerSid = "S-1-5-21-OTHER",
            },
        };

        const auto selection = wtcli::SelectPersistentSessionHost(records, "s-1-5-21-self", std::nullopt);
        VERIFY_ARE_EQUAL(static_cast<int>(wtcli::PersistentSessionHostSelectionStatus::Selected), static_cast<int>(selection.status));
        VERIFY_ARE_EQUAL(static_cast<size_t>(0), selection.selectedIndex);
        VERIFY_ARE_EQUAL(static_cast<size_t>(1), selection.eligibleCount);
    }

    void ProtocolParsingTests::PersistentSessionHostSelectionRequiresExplicitDesktopSessionWhenAmbiguous()
    {
        const std::vector<wtcli::PersistentSessionHostDiscoveryRecord> records{
            {
                .desktopSessionId = 4,
                .pid = 100u,
                .pipeName = "pipe-a",
                .ownerSid = "S-1-5-21-SELF",
            },
            {
                .desktopSessionId = 8,
                .pid = 200u,
                .pipeName = "pipe-b",
                .ownerSid = "S-1-5-21-SELF",
            },
        };

        const auto selection = wtcli::SelectPersistentSessionHost(records, "S-1-5-21-SELF", std::nullopt);
        VERIFY_ARE_EQUAL(static_cast<int>(wtcli::PersistentSessionHostSelectionStatus::Ambiguous), static_cast<int>(selection.status));
        VERIFY_ARE_EQUAL(static_cast<size_t>(2), selection.eligibleCount);
    }

    void ProtocolParsingTests::PersistentSessionHostSelectionHonorsExplicitDesktopSession()
    {
        const std::vector<wtcli::PersistentSessionHostDiscoveryRecord> records{
            {
                .desktopSessionId = 4,
                .pid = 100u,
                .pipeName = "pipe-a",
                .ownerSid = "S-1-5-21-SELF",
            },
            {
                .desktopSessionId = 8,
                .pid = 200u,
                .pipeName = "pipe-b",
                .ownerSid = "S-1-5-21-SELF",
            },
            {
                .desktopSessionId = 9,
                .pid = 300u,
                .pipeName = "pipe-c",
                .ownerSid = "S-1-5-21-OTHER",
            },
        };

        const auto explicitSelection = wtcli::SelectPersistentSessionHost(records, "S-1-5-21-SELF", 8u);
        VERIFY_ARE_EQUAL(static_cast<int>(wtcli::PersistentSessionHostSelectionStatus::Selected), static_cast<int>(explicitSelection.status));
        VERIFY_ARE_EQUAL(static_cast<size_t>(1), explicitSelection.selectedIndex);
        VERIFY_ARE_EQUAL(static_cast<size_t>(1), explicitSelection.eligibleCount);

        const auto missingSelection = wtcli::SelectPersistentSessionHost(records, "S-1-5-21-SELF", 10u);
        VERIFY_ARE_EQUAL(static_cast<int>(wtcli::PersistentSessionHostSelectionStatus::NotFound), static_cast<int>(missingSelection.status));
        VERIFY_ARE_EQUAL(static_cast<size_t>(0), missingSelection.eligibleCount);
    }
}
