// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "Formatting.h"

#include <cstdio>

void PrintJson(const Json::Value& val)
{
    Json::StreamWriterBuilder wb;
    wb["indentation"] = "  ";
    printf("%s\n", Json::writeString(wb, val).c_str());
}

// ── Human-readable formatters (read the server's JSON) ──

void FormatWindowsHuman(const Json::Value& windows)
{
    if (!windows.isArray() || windows.empty())
    {
        printf("No windows found.\n");
        return;
    }
    printf("%-12s %-30s %s\n", "WINDOW_ID", "TITLE", "FOCUSED");
    for (const auto& w : windows)
    {
        printf("%-12llu %-30s %s\n",
               static_cast<unsigned long long>(w["window_id"].asUInt64()),
               w["title"].asString().c_str(),
               w["is_focused"].asBool() ? "*" : "");
    }
}

void FormatTabsHuman(const Json::Value& tabs)
{
    if (!tabs.isArray() || tabs.empty())
    {
        printf("No tabs found.\n");
        return;
    }
    printf("%-10s %-30s %s\n", "TAB_ID", "TITLE", "FOCUSED");
    for (const auto& t : tabs)
    {
        printf("%-10u %-30s %s\n",
               t["tab_id"].asUInt(),
               t["title"].asString().c_str(),
               t["is_active"].asBool() ? "*" : "");
    }
}

void FormatPanesHuman(const Json::Value& panes)
{
    if (!panes.isArray() || panes.empty())
    {
        printf("No panes found.\n");
        return;
    }
    printf("%-38s %-8s %-8s %-10s %s\n", "SESSION_ID", "PID", "ACTIVE", "ROWS", "COLS");
    for (const auto& p : panes)
    {
        printf("%-38s %-8lu %-8s %-10d %d\n",
               p["session_id"].asString().c_str(),
               static_cast<unsigned long>(p["pid"].asUInt()),
               p["is_active"].asBool() ? "*" : "",
               p["size"]["rows"].asInt(),
               p["size"]["columns"].asInt());
    }
}

void FormatActivePaneHuman(const Json::Value& info)
{
    printf("Active pane: %s (tab: %u, window: %llu)\n",
           info["session_id"].asString().c_str(),
           info["tab_id"].asUInt(),
           static_cast<unsigned long long>(info["window_id"].asUInt64()));
}

void FormatPaneStatusHuman(const Json::Value& status)
{
    printf("State:     %s\n", status["state"].asString().c_str());
    printf("PID:       %lu\n", static_cast<unsigned long>(status["pid"].asUInt()));
    if (status.isMember("has_exit_code") ? status["has_exit_code"].asBool() : status.isMember("exit_code"))
        printf("Exit code: %d\n", status["exit_code"].asInt());
}

void FormatCreatedTabHuman(const Json::Value& result)
{
    printf("Created tab %u (session %s)\n",
           result["tab_id"].asUInt(),
           result["session_id"].asString().c_str());
}

void FormatCreatedPaneHuman(const Json::Value& result)
{
    printf("Created pane (session %s)\n", result["session_id"].asString().c_str());
}

void FormatPersistentSessionsHuman(const Json::Value& sessions)
{
    if (!sessions.isArray() || sessions.empty())
    {
        printf("No persistent sessions found.\n");
        return;
    }

    printf("%-8s %-38s %-20s %-9s %-10s %-8s %s\n", "DESKTOP", "SESSION_ID", "NAME", "STATE", "ATTACH", "PID", "TITLE");
    for (const auto& session : sessions)
    {
        printf("%-8u %-38s %-20s %-9s %-10s %-8u %s\n",
               session["desktop_session_id"].asUInt(),
               session["session_id"].asString().c_str(),
               session["name"].isString() ? session["name"].asString().c_str() : "",
               session["state"].isString() ? session["state"].asString().c_str() : "",
               session["attach_state"].isString() ? session["attach_state"].asString().c_str() : "",
               session["pid"].isUInt() ? session["pid"].asUInt() : 0,
               session["title"].isString() ? session["title"].asString().c_str() : "");
    }
}

void FormatPersistentSessionHuman(const Json::Value& session)
{
    printf("Session ID:        %s\n", session["session_id"].asString().c_str());
    printf("Name:              %s\n", session["name"].isString() ? session["name"].asString().c_str() : "");
    printf("Desktop session:   %u\n", session["desktop_session_id"].asUInt());
    printf("Window ID:         %llu\n", static_cast<unsigned long long>(session["window_id"].asUInt64()));
    printf("Tab ID:            %u\n", session["tab_id"].asUInt());
    printf("State:             %s\n", session["state"].isString() ? session["state"].asString().c_str() : "");
    printf("Attach state:      %s\n", session["attach_state"].isString() ? session["attach_state"].asString().c_str() : "");
    printf("PID:               %u\n", session["pid"].isUInt() ? session["pid"].asUInt() : 0);
    printf("Title:             %s\n", session["title"].isString() ? session["title"].asString().c_str() : "");
    printf("CWD:               %s\n", session["cwd"].isString() ? session["cwd"].asString().c_str() : "");
    if (session["has_exit_code"].asBool())
    {
        printf("Exit code:         %d\n", session["exit_code"].asInt());
    }
}
