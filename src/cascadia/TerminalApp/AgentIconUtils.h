// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include "../inc/AgentRegistry.h"

namespace Microsoft::Terminal::UI::AgentIcons
{
    inline winrt::Windows::UI::Xaml::ResourceDictionary& Resources()
    {
        thread_local winrt::Windows::UI::Xaml::ResourceDictionary resources{ nullptr };
        return resources;
    }

    inline winrt::Windows::UI::Xaml::Media::Geometry TakeGeometry(const winrt::Windows::UI::Xaml::Shapes::Path& shape)
    {
        const auto geometry = shape.Data();
        // Geometry has a single owner; detach it from the temporary template.
        shape.Data(nullptr);
        return geometry;
    }

    inline winrt::Windows::UI::Xaml::Media::Geometry GeometryForIconPath(const winrt::hstring& iconPath)
    {
        constexpr std::wstring_view prefix{ L"ms-appx:///AgentIcons/" };
        constexpr std::wstring_view suffix{ L".svg" };
        const std::wstring_view path{ iconPath };
        if (!path.starts_with(prefix) || !path.ends_with(suffix))
        {
            return nullptr;
        }
        const auto id = path.substr(prefix.size(), path.size() - prefix.size() - suffix.size());
        if (std::ranges::none_of(::Microsoft::Terminal::Settings::Model::AgentRegistry::BuiltinAcpAgents,
                                [&](const auto& agent) { return agent.id == id; }))
        {
            return nullptr;
        }
        namespace Xaml = winrt::Windows::UI::Xaml;
        const auto key = winrt::box_value(winrt::hstring{ L"AgentIcon." } + winrt::hstring{ id });
        const auto loaded = Resources().Lookup(key).as<Xaml::DataTemplate>().LoadContent();
        const auto content = loaded.as<Xaml::Controls::Viewbox>().Child();
        Xaml::Media::GeometryGroup group;
        if (const auto shape = content.try_as<Xaml::Shapes::Path>())
        {
            group.Children().Append(TakeGeometry(shape));
        }
        else
        {
            for (const auto& child : content.as<Xaml::Controls::Grid>().Children())
            {
                group.Children().Append(TakeGeometry(child.as<Xaml::Shapes::Path>()));
            }
        }
        const auto element = content.as<Xaml::FrameworkElement>();
        THROW_HR_IF_MSG(E_UNEXPECTED, !std::isfinite(element.Width()) || element.Width() <= 0 ||
                                         !std::isfinite(element.Height()) || element.Height() <= 0,
                        "Agent icon template must declare positive dimensions");
        Xaml::Media::ScaleTransform scale;
        scale.ScaleX(16.0 / element.Width());
        scale.ScaleY(16.0 / element.Height());
        group.Transform(scale);
        return group;
    }

    inline winrt::Microsoft::UI::Xaml::Controls::IconSource SourceForIconPath(const winrt::hstring& iconPath, const bool monochrome)
    {
        if (const auto geometry = GeometryForIconPath(iconPath))
        {
            winrt::Microsoft::UI::Xaml::Controls::PathIconSource source;
            source.Data(geometry);
            return source;
        }
        return winrt::Microsoft::Terminal::UI::IconPathConverter::IconSourceMUX(iconPath, monochrome);
    }

    inline winrt::Windows::UI::Xaml::Controls::IconElement ElementForIconPath(const winrt::hstring& iconPath)
    {
        if (const auto geometry = GeometryForIconPath(iconPath))
        {
            winrt::Windows::UI::Xaml::Controls::PathIcon icon;
            icon.Data(geometry);
            icon.Width(16);
            icon.Height(16);
            return icon;
        }
        return winrt::Microsoft::Terminal::UI::IconPathConverter::IconWUX(iconPath);
    }

    inline winrt::Microsoft::UI::Xaml::Controls::IconSource SourceForIconElement(const winrt::Windows::UI::Xaml::Controls::IconElement& value)
    {
        namespace MUX = winrt::Microsoft::UI::Xaml::Controls;
        namespace WUX = winrt::Windows::UI::Xaml::Controls;
        MUX::IconSource source{ nullptr };
        if (!value)
        {
            source = MUX::BitmapIconSource{};
        }
        else if (const auto element = value.try_as<WUX::IconSourceElement>())
        {
            const auto data = element.IconSource();
            if (const auto font = data.try_as<WUX::FontIconSource>())
            {
                MUX::FontIconSource converted;
                converted.Glyph(font.Glyph());
                converted.FontFamily(font.FontFamily());
                converted.FontSize(font.FontSize());
                converted.FontStyle(font.FontStyle());
                converted.FontWeight(font.FontWeight());
                converted.MirroredWhenRightToLeft(font.MirroredWhenRightToLeft());
                converted.IsTextScaleFactorEnabled(font.IsTextScaleFactorEnabled());
                source = converted;
            }
            else if (const auto bitmap = data.try_as<WUX::BitmapIconSource>())
            {
                MUX::BitmapIconSource converted;
                converted.UriSource(bitmap.UriSource());
                converted.ShowAsMonochrome(bitmap.ShowAsMonochrome());
                source = converted;
            }
            else if (const auto path = data.try_as<WUX::PathIconSource>())
            {
                MUX::PathIconSource converted;
                converted.Data(path.Data());
                source = converted;
            }
            else if (const auto symbol = data.try_as<WUX::SymbolIconSource>())
            {
                MUX::SymbolIconSource converted;
                converted.Symbol(symbol.Symbol());
                source = converted;
            }
            else
            {
                THROW_HR_IF(E_INVALIDARG, data);
            }
        }
        else if (const auto font = value.try_as<WUX::FontIcon>())
        {
            MUX::FontIconSource data;
            data.Glyph(font.Glyph());
            data.FontFamily(font.FontFamily());
            data.FontSize(font.FontSize());
            data.FontStyle(font.FontStyle());
            data.FontWeight(font.FontWeight());
            data.MirroredWhenRightToLeft(font.MirroredWhenRightToLeft());
            data.IsTextScaleFactorEnabled(font.IsTextScaleFactorEnabled());
            source = data;
        }
        else if (const auto bitmap = value.try_as<WUX::BitmapIcon>())
        {
            MUX::BitmapIconSource data;
            data.UriSource(bitmap.UriSource());
            data.ShowAsMonochrome(bitmap.ShowAsMonochrome());
            source = data;
        }
        else if (const auto path = value.try_as<WUX::PathIcon>())
        {
            MUX::PathIconSource data;
            data.Data(path.Data());
            source = data;
        }
        else if (const auto symbol = value.try_as<WUX::SymbolIcon>())
        {
            MUX::SymbolIconSource data;
            data.Symbol(symbol.Symbol());
            source = data;
        }
        else if (const auto image = value.try_as<MUX::ImageIcon>())
        {
            MUX::ImageIconSource data;
            data.ImageSource(image.Source());
            source = data;
        }
        else
        {
            THROW_HR(E_INVALIDARG);
        }
        if (!source)
        {
            source = MUX::BitmapIconSource{};
        }
        if (value)
        {
            source.Foreground(value.Foreground());
        }
        return source;
    }

    inline winrt::Windows::UI::Xaml::Controls::IconElement ElementForIconSource(const winrt::Microsoft::UI::Xaml::Controls::IconSource& source)
    {
        namespace MUX = winrt::Microsoft::UI::Xaml::Controls;
        namespace WUX = winrt::Windows::UI::Xaml::Controls;
        WUX::IconElement element{ nullptr };
        if (const auto font = source.try_as<MUX::FontIconSource>())
        {
            WUX::FontIcon icon;
            icon.Glyph(font.Glyph());
            icon.FontFamily(font.FontFamily());
            icon.FontSize(font.FontSize());
            icon.FontStyle(font.FontStyle());
            icon.FontWeight(font.FontWeight());
            icon.MirroredWhenRightToLeft(font.MirroredWhenRightToLeft());
            icon.IsTextScaleFactorEnabled(font.IsTextScaleFactorEnabled());
            element = icon;
        }
        else if (const auto bitmap = source.try_as<MUX::BitmapIconSource>())
        {
            WUX::BitmapIcon icon;
            icon.UriSource(bitmap.UriSource());
            icon.ShowAsMonochrome(bitmap.ShowAsMonochrome());
            element = icon;
        }
        else if (const auto path = source.try_as<MUX::PathIconSource>())
        {
            WUX::PathIcon icon;
            icon.Data(path.Data());
            icon.Width(16);
            icon.Height(16);
            element = icon;
        }
        else if (const auto symbol = source.try_as<MUX::SymbolIconSource>())
        {
            WUX::SymbolIcon icon;
            icon.Symbol(symbol.Symbol());
            element = icon;
        }
        else if (const auto image = source.try_as<MUX::ImageIconSource>())
        {
            MUX::ImageIcon icon;
            icon.Source(image.ImageSource());
            icon.Width(32);
            icon.Height(32);
            element = icon;
        }
        else
        {
            THROW_HR(E_INVALIDARG);
        }
        if (source.Foreground())
        {
            element.Foreground(source.Foreground());
        }
        return element;
    }
}
