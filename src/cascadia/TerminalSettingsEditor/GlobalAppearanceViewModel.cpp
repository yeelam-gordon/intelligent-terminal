// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "pch.h"
#include "GlobalAppearanceViewModel.h"
#include "GlobalAppearanceViewModel.g.cpp"
#include "EnumEntry.h"

using namespace winrt;
using namespace winrt::Windows::UI::Xaml;
using namespace winrt::Windows::UI::Xaml::Navigation;
using namespace winrt::Windows::UI::Xaml::Controls;
using namespace winrt::Microsoft::Terminal::Settings::Model;
using namespace winrt::Windows::Foundation::Collections;

namespace winrt::Microsoft::Terminal::Settings::Editor::implementation
{
    constexpr std::wstring_view systemThemeName{ L"system" };
    constexpr std::wstring_view darkThemeName{ L"dark" };
    constexpr std::wstring_view lightThemeName{ L"light" };
    constexpr std::wstring_view legacySystemThemeName{ L"legacySystem" };
    constexpr std::wstring_view legacyDarkThemeName{ L"legacyDark" };
    constexpr std::wstring_view legacyLightThemeName{ L"legacyLight" };

    GlobalAppearanceViewModel::GlobalAppearanceViewModel(Model::GlobalAppSettings globalSettings) :
        _GlobalSettings{ globalSettings },
        _ThemeList{ single_threaded_observable_vector<Model::Theme>() }
    {
        INITIALIZE_BINDABLE_ENUM_SETTING(NewTabPosition, NewTabPosition, NewTabPosition, L"Globals_NewTabPosition", L"Content");
        INITIALIZE_BINDABLE_ENUM_SETTING(TabWidthMode, TabViewWidthMode, winrt::Microsoft::UI::Xaml::Controls::TabViewWidthMode, L"Globals_TabWidthMode", L"Content");
        INITIALIZE_BINDABLE_ENUM_SETTING(TabLayout, TabLayout, Model::TabLayout, L"Globals_TabLayout", L"Content");
        _UpdateThemeList();
    }

    // Function Description:
    // - Updates the list of all themes available to choose from.
    void GlobalAppearanceViewModel::_UpdateThemeList()
    {
        // Surprisingly, though this is called every time we navigate to the page,
        // the list does not keep growing on each navigation.
        const auto& ThemeMap{ _GlobalSettings.Themes() };
        for (const auto& pair : ThemeMap)
        {
            _ThemeList.Append(pair.Value());
        }
    }

    winrt::Windows::Foundation::IInspectable GlobalAppearanceViewModel::CurrentTheme()
    {
        if (!_currentTheme)
        {
            _currentTheme = _GlobalSettings.CurrentTheme();
        }
        return _currentTheme;
    }

    // Get the name out of the newly selected item, stash that as the Theme name
    // set for the globals. That controls which theme is actually the current
    // theme.
    void GlobalAppearanceViewModel::CurrentTheme(const winrt::Windows::Foundation::IInspectable& tag)
    {
        if (const auto& theme{ tag.try_as<Model::Theme>() })
        {
            _GlobalSettings.Theme(Model::ThemePair{ theme.Name() });
            if (theme.Name() == darkThemeName || theme.Name() == legacyDarkThemeName)
            {
                _GlobalSettings.TabWidthMode(winrt::Microsoft::UI::Xaml::Controls::TabViewWidthMode::Compact);
                _GlobalSettings.NewTabPosition(Model::NewTabPosition::AfterCurrentTab);
            }
            else
            {
                _GlobalSettings.TabWidthMode(winrt::Microsoft::UI::Xaml::Controls::TabViewWidthMode::Equal);
                _GlobalSettings.NewTabPosition(Model::NewTabPosition::AfterLastTab);
            }
        }
    }

    // Method Description:
    // - Convert the names of the inbox themes to some more descriptive,
    //   well-known values. If the passed in theme isn't an inbox one, then just
    //   return its set Name.
    //    - "light" becomes "Light"
    //    - "dark" becomes "Dark"
    //    - "system" becomes "Use Windows theme"
    // - These values are all localized based on the app language.
    // Arguments:
    // - theme: the theme to get the display name for.
    // Return Value:
    // - the potentially localized name to use for this Theme.
    winrt::hstring GlobalAppearanceViewModel::ThemeNameConverter(const Model::Theme& theme)
    {
        const auto name = theme.Name();
        if (name == darkThemeName)
        {
            return RS_(L"Globals_ThemeDark/Content");
        }
        else if (name == lightThemeName)
        {
            return RS_(L"Globals_ThemeLight/Content");
        }
        else if (name == systemThemeName)
        {
            return RS_(L"Globals_ThemeSystem/Content");
        }
        else if (name == legacyDarkThemeName)
        {
            return RS_(L"Globals_ThemeDarkLegacy/Content");
        }
        else if (name == legacyLightThemeName)
        {
            return RS_(L"Globals_ThemeLightLegacy/Content");
        }
        else if (name == legacySystemThemeName)
        {
            return RS_(L"Globals_ThemeSystemLegacy/Content");
        }
        return name;
    }

    bool GlobalAppearanceViewModel::InvertedDisableAnimations()
    {
        return _DispatchAppearanceAction({ L"DisableAnimations", false, false, true });
    }

    void GlobalAppearanceViewModel::InvertedDisableAnimations(bool value)
    {
        _DispatchAppearanceAction({ L"DisableAnimations", true, value, true });
    }

    bool GlobalAppearanceViewModel::_DispatchAppearanceAction(const AppearanceAction& action)
    {
        if (action.write)
        {
            const auto value = action.invert ? !action.value : action.value;
            _WriteAppearanceValue(action.property, value);
            return action.value;
        }

        const auto value = _ReadAppearanceValue(action.property);
        return action.invert ? !value : value;
    }

    bool GlobalAppearanceViewModel::_ReadAppearanceValue(const std::wstring_view property)
    {
        if (property == L"DisableAnimations")
        {
            return _GlobalSettings.DisableAnimations();
        }
        if (property == L"ShowTabsInTitlebar")
        {
            return ShowTabsInTitlebar();
        }
        if (property == L"AlwaysShowTabs")
        {
            return AlwaysShowTabs();
        }
        return false;
    }

    void GlobalAppearanceViewModel::_WriteAppearanceValue(const std::wstring_view property, const bool value)
    {
        if (property == L"DisableAnimations")
        {
            _GlobalSettings.DisableAnimations(value);
        }
        else if (property == L"ShowTabsInTitlebar")
        {
            ShowTabsInTitlebar(value);
        }
        else if (property == L"AlwaysShowTabs")
        {
            AlwaysShowTabs(value);
        }
    }

    void GlobalAppearanceViewModel::ShowTitlebarToggled(const winrt::Windows::Foundation::IInspectable& /* sender */, const RoutedEventArgs& /* args */)
    {
        // Set AlwaysShowTabs to true if ShowTabsInTitlebar was toggled OFF -> ON
        if (_DispatchAppearanceAction({ L"ShowTabsInTitlebar", false, false, true }))
        {
            _DispatchAppearanceAction({ L"AlwaysShowTabs", true, true, false });
        }
    }
}
