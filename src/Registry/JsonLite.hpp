// MetalCompat internal — minimal strict JSON reader for the registry format.
// Zero dependencies: the registry format is project-owned, so a small reader is
// justified over adding a vendored library (SPEC 13.1 dependency policy).
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mc::json {

struct Value;
using ValuePtr = std::unique_ptr<Value>;

struct Member { std::string key; ValuePtr value; };
struct Elem   { ValuePtr value; };

struct Value {
    enum class Type : std::uint8_t { Null, Bool, Number, String, Object, Array };
    Type type = Type::Null;
    // payloads
    bool b = false;
    double num = 0.0;
    std::string str;
    std::vector<Member> obj;
    std::vector<Elem> arr;

    const Value* find(const char* key) const noexcept {
        if (type != Type::Object) return nullptr;
        for (auto& m : obj)
            if (m.key == key) return m.value.get();
        return nullptr;
    }
    const Value* at(size_t i) const noexcept {
        return type == Type::Array && i < arr.size() ? arr[i].value.get() : nullptr;
    }
    size_t size() const noexcept { return type == Type::Array ? arr.size() : 0; }
    bool asString(std::string& out) const noexcept {
        if (type != Type::String) return false;
        out = str; return true;
    }
    bool asNumber(int& out) const noexcept {
        if (type != Type::Number) return false;
        out = static_cast<int>(num); return true;
    }
    bool asNumber(std::int64_t& out) const noexcept {
        if (type != Type::Number) return false;
        out = static_cast<std::int64_t>(num); return true;
    }
    bool isNull() const noexcept { return type == Type::Null; }
};

struct ParseResult {
    ValuePtr value;
    std::string error; // empty on success
};

// Parses fully; rejects trailing content. UTF-8 in, validated for structure.
ParseResult parse(const std::string& source) noexcept;

} // namespace mc::json
