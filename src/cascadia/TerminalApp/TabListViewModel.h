// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <ranges>
#include <span>

namespace TerminalApp
{
    class TabListViewModel
    {
    public:
        struct OwnerEntry
        {
            const void* identity;
            uint32_t canonicalIndex;
            bool isPinned;
            bool isEligible;
        };

        struct Target
        {
            const void* identity;
            uint32_t canonicalIndex;
        };

        enum class MoveDirection
        {
            Previous,
            Next,
        };

        // Borrows immutable canonical-order metadata with the canonical pinned prefix.
        // The backing storage must outlive this object; identity tokens are
        // compared, never dereferenced, even when an explicit span is supplied.
        explicit constexpr TabListViewModel(std::span<const OwnerEntry> owners) noexcept :
            _owners{ owners }
        {
        }

        template<typename Owners>
            requires(std::ranges::contiguous_range<Owners> && !std::ranges::borrowed_range<Owners>)
        TabListViewModel(Owners&&) = delete;

        template<typename Callback>
        void ForEachOwner(Callback&& callback) const
        {
            for (const auto& owner : _owners)
            {
                callback(owner, owner.isEligible);
            }
        }

        [[nodiscard]] bool IsPresented(const void* identity) const noexcept
        {
            for (const auto& owner : _owners)
            {
                if (owner.identity == identity)
                {
                    return owner.isEligible;
                }
            }
            return false;
        }

        [[nodiscard]] std::optional<Target> PresentedAt(uint32_t ordinal) const noexcept
        {
            for (const auto& owner : _owners)
            {
                if (owner.isEligible)
                {
                    if (ordinal == 0)
                    {
                        return Target{ owner.identity, owner.canonicalIndex };
                    }
                    --ordinal;
                }
            }
            return std::nullopt;
        }

        [[nodiscard]] std::optional<Target> LastPresented() const noexcept
        {
            for (auto i = _owners.size(); i > 0; --i)
            {
                const auto& owner = _owners[i - 1];
                if (owner.isEligible)
                {
                    return Target{ owner.identity, owner.canonicalIndex };
                }
            }
            return std::nullopt;
        }

        [[nodiscard]] std::optional<Target> MoveTarget(const void* identity, MoveDirection direction) const noexcept
        {
            for (std::size_t i = 0; i < _owners.size(); ++i)
            {
                const auto& owner = _owners[i];
                if (owner.identity != identity)
                {
                    continue;
                }
                if (!owner.isEligible)
                {
                    return std::nullopt;
                }
                if (direction == MoveDirection::Previous)
                {
                    while (i > 0)
                    {
                        const auto& neighbor = _owners[--i];
                        if (neighbor.isPinned != owner.isPinned)
                        {
                            break;
                        }
                        if (neighbor.isEligible)
                        {
                            return Target{ neighbor.identity, neighbor.canonicalIndex };
                        }
                    }
                }
                else
                {
                    while (++i < _owners.size())
                    {
                        const auto& neighbor = _owners[i];
                        if (neighbor.isPinned != owner.isPinned)
                        {
                            break;
                        }
                        if (neighbor.isEligible)
                        {
                            return Target{ neighbor.identity, neighbor.canonicalIndex };
                        }
                    }
                }
                return std::nullopt;
            }
            return std::nullopt;
        }

    private:
        std::span<const OwnerEntry> _owners;
    };
}
