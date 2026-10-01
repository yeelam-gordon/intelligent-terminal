// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include "IndeterminateProgressRing.g.h"
#include "IndeterminateProgressRingAutomationPeer.g.h"

namespace TerminalAppLocalTests
{
    class TabTests;
}

namespace winrt::TerminalApp::implementation
{
    struct IndeterminateProgressRing : IndeterminateProgressRingT<IndeterminateProgressRing>
    {
        IndeterminateProgressRing();
        ~IndeterminateProgressRing();

        void OnApplyTemplate();
        Windows::UI::Xaml::Automation::Peers::AutomationPeer OnCreateAutomationPeer();
        DEPENDENCY_PROPERTY(bool, IsActive);

    private:
        friend class ::TerminalAppLocalTests::TabTests;

        struct VisibilitySubscription
        {
            winrt::weak_ref<Windows::UI::Xaml::UIElement> element;
            int64_t token;
        };

        void _ObserveVisibility();
        void _ClearVisibilityObservers();
        void _UpdateAnimation();
        void _StopAnimation();

        std::vector<VisibilitySubscription> _visibilitySubscriptions;
        Windows::UI::Xaml::Media::Animation::Storyboard _storyboard{ nullptr };
        bool _loaded{ false };
        bool _running{ false };
    };

    struct IndeterminateProgressRingAutomationPeer : IndeterminateProgressRingAutomationPeerT<IndeterminateProgressRingAutomationPeer>
    {
        IndeterminateProgressRingAutomationPeer(const TerminalApp::IndeterminateProgressRing& owner);
        winrt::hstring GetClassNameCore() const;
        Windows::UI::Xaml::Automation::Peers::AutomationControlType GetAutomationControlTypeCore() const;
    };
}

namespace winrt::TerminalApp::factory_implementation
{
    BASIC_FACTORY(IndeterminateProgressRing);
    BASIC_FACTORY(IndeterminateProgressRingAutomationPeer);
}
