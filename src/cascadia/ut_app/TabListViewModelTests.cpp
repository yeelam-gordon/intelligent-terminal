// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "precomp.h"

#include "../TerminalApp/TabListViewModel.h"

#include <array>
#include <limits>
#include <type_traits>
#include <vector>

using namespace WEX::TestExecution;
using ViewModel = TerminalApp::TabListViewModel;
using Entry = ViewModel::OwnerEntry;
using Direction = ViewModel::MoveDirection;

static_assert(std::is_trivially_copyable_v<Entry>);
static_assert(std::is_trivially_copyable_v<ViewModel>);
static_assert(std::is_constructible_v<ViewModel, std::array<Entry, 4>&>);
static_assert(std::is_constructible_v<ViewModel, const std::array<Entry, 4>&>);
static_assert(!std::is_constructible_v<ViewModel, std::array<Entry, 4>&&>);
static_assert(!std::is_constructible_v<ViewModel, const std::array<Entry, 4>&&>);
static_assert(std::is_constructible_v<ViewModel, std::vector<Entry>&>);
static_assert(std::is_constructible_v<ViewModel, const std::vector<Entry>&>);
static_assert(!std::is_constructible_v<ViewModel, std::vector<Entry>&&>);
static_assert(!std::is_constructible_v<ViewModel, const std::vector<Entry>&&>);
static_assert(std::is_constructible_v<ViewModel, std::span<const Entry>>);
static_assert(std::is_constructible_v<ViewModel, std::span<Entry>>);

namespace TerminalAppUnitTests
{
    class TabListViewModelTests
    {
        TEST_CLASS(TabListViewModelTests);

        TEST_METHOD(AllOwnersAndFilteredOwners);
        TEST_METHOD(EmptyAndNobodyEligible);
        TEST_METHOD(OrdinalBoundsAndExplicitLast);
        TEST_METHOD(HiddenNeighborsAndMissingOwners);
        TEST_METHOD(PinPartitions);
        TEST_METHOD(FreshSnapshots);
        TEST_METHOD(MetadataAndIdentityRemainUnchanged);
    };

    void TabListViewModelTests::AllOwnersAndFilteredOwners()
    {
        const std::array<int, 4> identities{};
        std::array<Entry, 4> entries{};
        for (uint32_t i = 0; i < entries.size(); ++i)
        {
            entries[i] = { &identities[i], i, false, true };
        }
        const ViewModel all{ entries };
        for (uint32_t i = 0; i < entries.size(); ++i)
        {
            const auto target = all.PresentedAt(i);
            VERIFY_IS_TRUE(target.has_value());
            VERIFY_IS_TRUE(target->identity == &identities[i]);
            VERIFY_ARE_EQUAL(i, target->canonicalIndex);
        }
        VERIFY_IS_TRUE(all.MoveTarget(&identities[3], Direction::Previous)->identity == &identities[2]);
        entries[0].isEligible = false;
        entries[2].isEligible = false;
        const ViewModel filtered{ entries };
        uint32_t ordinal = 0;
        uint32_t visited = 0;
        filtered.ForEachOwner([&](const Entry& entry, bool presented) {
            ++visited;
            if (presented)
            {
                VERIFY_IS_TRUE(entry.identity == filtered.PresentedAt(ordinal++)->identity);
            }
        });
        VERIFY_ARE_EQUAL(4u, visited);
        VERIFY_ARE_EQUAL(2u, ordinal);
        VERIFY_IS_TRUE(filtered.PresentedAt(0)->identity == &identities[1]);
        VERIFY_IS_TRUE(filtered.PresentedAt(1)->identity == &identities[3]);
        VERIFY_ARE_EQUAL(3u, filtered.LastPresented()->canonicalIndex);
    }

    void TabListViewModelTests::EmptyAndNobodyEligible()
    {
        const int identity{};
        const std::array<Entry, 1> entries{ Entry{ &identity, 0, false, false } };
        const ViewModel empty{ std::span<const Entry>{} };
        const ViewModel nobody{ entries };
        for (const auto* view : { &empty, &nobody })
        {
            VERIFY_IS_FALSE(view->PresentedAt(0).has_value());
            VERIFY_IS_FALSE(view->PresentedAt(7).has_value());
            VERIFY_IS_FALSE(view->PresentedAt(std::numeric_limits<uint32_t>::max()).has_value());
            VERIFY_IS_FALSE(view->LastPresented().has_value());
            VERIFY_IS_FALSE(view->IsPresented(&identity));
            VERIFY_IS_FALSE(view->MoveTarget(&identity, Direction::Previous).has_value());
            VERIFY_IS_FALSE(view->MoveTarget(&identity, Direction::Next).has_value());
        }
        uint32_t count = 0;
        empty.ForEachOwner([&](const Entry&, bool) { ++count; });
        VERIFY_ARE_EQUAL(0u, count);
    }

    void TabListViewModelTests::OrdinalBoundsAndExplicitLast()
    {
        const std::array<int, 12> identities{};
        std::array<Entry, 12> entries{};
        for (uint32_t i = 0; i < entries.size(); ++i)
        {
            entries[i] = { &identities[i], i, false, true };
        }
        const ViewModel view{ entries };
        VERIFY_ARE_EQUAL(7u, view.PresentedAt(7)->canonicalIndex);
        VERIFY_ARE_EQUAL(11u, view.LastPresented()->canonicalIndex);
        VERIFY_IS_FALSE(view.PresentedAt(12).has_value());
        VERIFY_IS_FALSE(view.PresentedAt(std::numeric_limits<uint32_t>::max()).has_value());
        VERIFY_IS_FALSE(view.MoveTarget(&identities.front(), Direction::Previous).has_value());
        VERIFY_IS_FALSE(view.MoveTarget(&identities.back(), Direction::Next).has_value());
    }

    void TabListViewModelTests::HiddenNeighborsAndMissingOwners()
    {
        const int a{}, b{}, c{}, d{}, missing{};
        const std::array entries{
            Entry{ &a, 0, false, false }, Entry{ &b, 1, false, true },
            Entry{ &c, 2, false, false }, Entry{ &d, 3, false, true }
        };
        const ViewModel view{ entries };
        VERIFY_IS_TRUE(view.MoveTarget(&d, Direction::Previous)->identity == &b);
        VERIFY_ARE_EQUAL(1u, view.MoveTarget(&d, Direction::Previous)->canonicalIndex);
        VERIFY_IS_TRUE(view.MoveTarget(&b, Direction::Next)->identity == &d);
        VERIFY_IS_TRUE(view.IsPresented(&b));
        VERIFY_IS_FALSE(view.MoveTarget(&b, Direction::Previous).has_value());
        for (const auto* identity : { &a, &c, &missing })
        {
            VERIFY_IS_FALSE(view.IsPresented(identity));
            VERIFY_IS_FALSE(view.MoveTarget(identity, Direction::Previous).has_value());
            VERIFY_IS_FALSE(view.MoveTarget(identity, Direction::Next).has_value());
        }
    }

    void TabListViewModelTests::PinPartitions()
    {
        const std::array<int, 8> identities{};
        std::array<Entry, 8> entries{};
        for (uint32_t i = 0; i < entries.size(); ++i)
        {
            entries[i] = { &identities[i], i, i < 4, i % 2 == 0 };
        }
        const ViewModel view{ entries };
        VERIFY_ARE_EQUAL(0u, view.MoveTarget(&identities[2], Direction::Previous)->canonicalIndex);
        VERIFY_ARE_EQUAL(2u, view.MoveTarget(&identities[0], Direction::Next)->canonicalIndex);
        VERIFY_IS_FALSE(view.MoveTarget(&identities[2], Direction::Next).has_value());
        VERIFY_IS_FALSE(view.MoveTarget(&identities[4], Direction::Previous).has_value());
        VERIFY_ARE_EQUAL(6u, view.MoveTarget(&identities[4], Direction::Next)->canonicalIndex);
        VERIFY_ARE_EQUAL(4u, view.MoveTarget(&identities[6], Direction::Previous)->canonicalIndex);
        VERIFY_ARE_EQUAL(4u, view.PresentedAt(2)->canonicalIndex);
        for (const bool pinned : { false, true })
        {
            for (auto& entry : entries)
            {
                entry.isPinned = pinned;
            }
            const ViewModel onePartition{ entries };
            VERIFY_ARE_EQUAL(4u, onePartition.MoveTarget(&identities[2], Direction::Next)->canonicalIndex);
        }
    }

    void TabListViewModelTests::FreshSnapshots()
    {
        const int a{}, b{}, c{}, d{};
        const std::array original{
            Entry{ &a, 0, false, false }, Entry{ &b, 1, false, true },
            Entry{ &c, 2, false, false }, Entry{ &d, 3, false, true }
        };
        const std::array reordered{
            Entry{ &a, 0, false, false }, Entry{ &d, 1, false, true },
            Entry{ &b, 2, false, true }, Entry{ &c, 3, false, false }
        };
        const ViewModel before{ original };
        const ViewModel after{ reordered };
        VERIFY_IS_TRUE(before.PresentedAt(0)->identity == &b);
        VERIFY_IS_TRUE(after.PresentedAt(0)->identity == &d);
        VERIFY_ARE_EQUAL(2u, after.MoveTarget(&d, Direction::Next)->canonicalIndex);
        auto changed = reordered;
        changed[1].isEligible = false;
        const ViewModel newEligibility{ changed };
        VERIFY_IS_TRUE(newEligibility.PresentedAt(0)->identity == &b);
        VERIFY_IS_FALSE(newEligibility.IsPresented(&d));
        VERIFY_IS_TRUE(after.IsPresented(&d));
    }

    void TabListViewModelTests::MetadataAndIdentityRemainUnchanged()
    {
        const int mixedOwner = 42;
        const std::array entries{ Entry{ &mixedOwner, 17, true, true } };
        const ViewModel view{ entries };
        uint32_t count = 0;
        view.ForEachOwner([&](const Entry& entry, bool presented) {
            ++count;
            VERIFY_IS_TRUE(&entry == &entries[0]);
            VERIFY_IS_TRUE(presented);
        });
        VERIFY_ARE_EQUAL(1u, count);
        VERIFY_IS_TRUE(view.PresentedAt(0)->identity == &mixedOwner);
        VERIFY_ARE_EQUAL(17u, view.PresentedAt(0)->canonicalIndex);
        VERIFY_IS_FALSE(view.PresentedAt(1).has_value());
        VERIFY_IS_FALSE(view.MoveTarget(&mixedOwner, Direction::Next).has_value());
        VERIFY_IS_TRUE(entries[0].isPinned);
        VERIFY_IS_TRUE(entries[0].isEligible);
        VERIFY_ARE_EQUAL(17u, entries[0].canonicalIndex);
        VERIFY_ARE_EQUAL(42, mixedOwner);
    }
}
