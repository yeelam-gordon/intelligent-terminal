// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "pch.h"
#include <winrt/Windows.UI.Xaml.Interop.h>
#include "IndeterminateProgressRing.h"

#include "IndeterminateProgressRing.g.cpp"
#include "IndeterminateProgressRingAutomationPeer.g.cpp"

using namespace winrt;
using namespace winrt::Windows::UI::Xaml;
using namespace winrt::Windows::UI::Xaml::Media;
using namespace winrt::Windows::UI::Xaml::Media::Animation;

namespace winrt::TerminalApp::implementation
{
    DependencyProperty IndeterminateProgressRing::_IsActiveProperty{ nullptr };

    IndeterminateProgressRing::IndeterminateProgressRing()
    {
        static const auto registered = [] {
            _IsActiveProperty = DependencyProperty::Register(
                L"IsActive",
                xaml_typename<bool>(),
                xaml_typename<TerminalApp::IndeterminateProgressRing>(),
                PropertyMetadata{ box_value(false), [](const DependencyObject& sender, const DependencyPropertyChangedEventArgs&) {
                                     get_self<IndeterminateProgressRing>(sender.as<TerminalApp::IndeterminateProgressRing>())->_UpdateAnimation();
                                 } });
            return true;
        }();
        (void)registered;

        Loaded([weakThis = get_weak()](auto&&, auto&&) {
            if (const auto self = weakThis.get())
            {
                self->_loaded = true;
                self->_ObserveVisibility();
                self->_UpdateAnimation();
            }
        });
        Unloaded([weakThis = get_weak()](auto&&, auto&&) {
            if (const auto self = weakThis.get())
            {
                self->_loaded = false;
                self->_StopAnimation();
                self->_ClearVisibilityObservers();
            }
        });
    }

    IndeterminateProgressRing::~IndeterminateProgressRing()
    {
        try
        {
            _StopAnimation();
            _ClearVisibilityObservers();
        }
        CATCH_LOG();
    }

    void IndeterminateProgressRing::OnApplyTemplate()
    {
        _StopAnimation();
        _storyboard = nullptr;
        if (const auto view = GetTemplateChild(L"SpinnerView").try_as<FrameworkElement>())
        {
            if (const auto rotation = view.RenderTransform().try_as<RotateTransform>())
            {
                DoubleAnimation animation;
                animation.From(0.0);
                animation.To(360.0);
                animation.Duration(DurationHelper::FromTimeSpan(std::chrono::seconds{ 1 }));
                animation.RepeatBehavior(RepeatBehaviorHelper::Forever());
                Storyboard::SetTarget(animation, rotation);
                Storyboard::SetTargetProperty(animation, L"Angle");
                _storyboard = Storyboard{};
                _storyboard.Children().Append(animation);
            }
        }
        _UpdateAnimation();
    }

    Automation::Peers::AutomationPeer IndeterminateProgressRing::OnCreateAutomationPeer()
    {
        return make<IndeterminateProgressRingAutomationPeer>(*this);
    }

    void IndeterminateProgressRing::_ObserveVisibility()
    {
        _ClearVisibilityObservers();
        // Visibility is not inherited as a dependency property. Observe the attached
        // visual ancestry, not the progress model, and release it on every unload.
        for (DependencyObject current = *this; current; current = VisualTreeHelper::GetParent(current))
        {
            if (const auto element = current.try_as<UIElement>())
            {
                const auto token = element.RegisterPropertyChangedCallback(UIElement::VisibilityProperty(), [weakThis = get_weak()](auto&&, auto&&) {
                    if (const auto self = weakThis.get())
                    {
                        self->_UpdateAnimation();
                    }
                });
                _visibilitySubscriptions.push_back({ make_weak(element), token });
            }
        }
    }

    void IndeterminateProgressRing::_ClearVisibilityObservers()
    {
        for (const auto& subscription : _visibilitySubscriptions)
        {
            if (const auto element = subscription.element.get())
            {
                element.UnregisterPropertyChangedCallback(UIElement::VisibilityProperty(), subscription.token);
            }
        }
        _visibilitySubscriptions.clear();
    }

    void IndeterminateProgressRing::_UpdateAnimation()
    {
        auto visible = _loaded && IsActive() && _storyboard;
        if (visible)
        {
            for (const auto& subscription : _visibilitySubscriptions)
            {
                const auto element = subscription.element.get();
                if (!element || element.Visibility() != Visibility::Visible)
                {
                    visible = false;
                    break;
                }
            }
        }
        if (visible && !_running)
        {
            _storyboard.Begin();
            _running = true;
        }
        else if (!visible)
        {
            _StopAnimation();
        }
    }

    void IndeterminateProgressRing::_StopAnimation()
    {
        if (_running)
        {
            _storyboard.Stop();
            _running = false;
        }
    }

    IndeterminateProgressRingAutomationPeer::IndeterminateProgressRingAutomationPeer(const TerminalApp::IndeterminateProgressRing& owner) :
        IndeterminateProgressRingAutomationPeerT<IndeterminateProgressRingAutomationPeer>(owner)
    {
    }

    winrt::hstring IndeterminateProgressRingAutomationPeer::GetClassNameCore() const
    {
        return L"ProgressRing";
    }

    Automation::Peers::AutomationControlType IndeterminateProgressRingAutomationPeer::GetAutomationControlTypeCore() const
    {
        return Automation::Peers::AutomationControlType::ProgressBar;
    }
}
