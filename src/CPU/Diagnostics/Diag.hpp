// MetalCompat internal — opt-in diagnostics ring buffer (SPEC §4.2.8).
// Zero effect when disabled; no app content or shader source is ever recorded.
#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <string>
#include <utility>

namespace mc::diag {

enum class EventKind : std::uint8_t {
    FeatureSelected,
    FallbackReason,
    PlanUnsupported,
    PipelineCacheHit,
    PipelineCacheMiss,
    CommandPreparationMs100,
    SubmissionMs100,
};

struct Event {
    std::uint64_t id = 0;
    EventKind kind = EventKind::FeatureSelected;
    std::string featureId;   ///< registry id only — never user content
    std::string detail;      ///< static/internal text only
};

class Diagnostics {
public:
    void enable() noexcept { enabled_.store(true); }
    void disable() noexcept { enabled_.store(false); }
    bool enabled() const noexcept { return enabled_.load(std::memory_order_relaxed); }

    static constexpr size_t kCapacity = 256;

    void record(EventKind kind, std::string featureId, std::string detail = {}) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        const auto seq = next_.fetch_add(1, std::memory_order_relaxed);
        Event& slot = ring_[seq % kCapacity];
        slot.id = seq;
        slot.kind = kind;
        slot.featureId = std::move(featureId);
        slot.detail = std::move(detail);
    }

    size_t populatedCount() const noexcept {
        const auto next = next_.load(std::memory_order_relaxed);
        return next < kCapacity ? next : kCapacity;
    }

    const Event* snapshot(size_t i) const noexcept {
        if (i >= kCapacity) return nullptr;
        return &ring_[i];
    }

    void clear() noexcept {
        next_.store(0, std::memory_order_relaxed);
        for (auto& e : ring_) e = Event{};
    }

private:
    std::array<Event, kCapacity> ring_{};
    std::atomic<std::uint64_t> next_{0};
    std::atomic<bool> enabled_{false};
};

// process-wide singleton (slice stage; backend injects its own later)
Diagnostics& global() noexcept;

} // namespace mc::diag
