// Minimal strict JSON parser (subset adequate for the MetalCompat registry):
// objects, arrays, strings with escapes, numbers, true/false/null.
// Strict: duplicate keys rejected, unquoted keys rejected, trailing content
// rejected. Errors carry "L<line>:C<col>" positions.
#include "JsonLite.hpp"

#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace mc::json {
namespace {

struct Cursor {
    const char* p = nullptr;
    const char* end = nullptr;
    size_t line = 0, col = 0;
    explicit Cursor(const std::string& s) : p(s.data()), end(s.data() + s.size()), line(1), col(1) {}
    bool eof() const noexcept { return p >= end; }
    char peek() const noexcept { return eof() ? '\0' : *p; }
    char next() noexcept {
        if (eof()) return '\0';
        char c = *p++;
        if (c == '\n') { ++line; col = 1; } else { ++col; }
        return c;
    }
    std::string pos() const noexcept {
        return "L" + std::to_string(line) + ":C" + std::to_string(col);
    }
};

void skipWhitespace(Cursor& c) noexcept {
    while (!c.eof()) {
        char ch = *c.p;
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') c.next();
        else break;
    }
}

bool parseString(Cursor& c, std::string& out, std::string& err) {
    if (c.next() != '"') { err = c.pos() + ": expected string opening '\"'"; return false; }
    out.clear();
    for (;;) {
        if (c.eof()) { err = c.pos() + ": unterminated string"; return false; }
        char ch = c.next();
        if (ch == '"') return true;
        if (ch != '\\') {
            if (static_cast<unsigned char>(ch) < 0x20) {
                err = c.pos() + ": control char in string";
                return false;
            }
            out.push_back(ch);
            continue;
        }
        // escape
        switch (c.next()) {
            case '"':  out.push_back('"');  break;
            case '\\': out.push_back('\\'); break;
            case '/':  out.push_back('/');  break;
            case 'b':  out.push_back('\b'); break;
            case 'f':  out.push_back('\f'); break;
            case 'n':  out.push_back('\n'); break;
            case 'r':  out.push_back('\r'); break;
            case 't':  out.push_back('\t'); break;
            case 'u': {
                unsigned code = 0;
                for (int i = 0; i < 4; ++i) {
                    char h = c.next();
                    code <<= 4;
                    if (h >= '0' && h <= '9') code |= static_cast<unsigned>(h - '0');
                    else if (h >= 'a' && h <= 'f') code |= static_cast<unsigned>(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') code |= static_cast<unsigned>(h - 'A' + 10);
                    else { err = c.pos() + ": bad \\u escape"; return false; }
                }
                // encode UTF-8 (surrogate pairs form their own sequences here;
                // registry keys/content are ASCII-latin, so simple fast path +
                // correct surrogate trimming is enough for validation purposes)
                if (code >= 0xD800 && code <= 0xDFFF) {
                    out.push_back('?');
                } else if (code < 0x80) {
                    out.push_back(static_cast<char>(code));
                } else if (code < 0x800) {
                    out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                } else {
                    out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                    out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                }
                break;
            }
            case '\0':
                err = c.pos() + ": truncated escape";
                return false;
            default:
                err = c.pos() + ": invalid escape";
                return false;
        }
    }
}

bool parseNumber(Cursor& c, double& out, std::string& err) {
    const char* start = c.p;
    while (!c.eof()) {
        char ch = c.peek();
        bool ok = (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' ||
                  ch == 'e' || ch == 'E';
        if (!ok) break;
        c.next();
    }
    const char* upto = c.p;
    if (start == upto) { err = c.pos() + ": invalid number"; return false; }
    errno = 0;
    char* stop = nullptr;
    out = std::strtod(start, &stop);
    if (stop != upto || errno == ERANGE) { err = c.pos() + ": malformed number"; return false; }
    return true;
}

bool parseValue(Cursor& c, ValuePtr& out, std::string& err);

bool parseObject(Cursor& c, ValuePtr& out, std::string& err) {
    c.next(); // '{'
    out = std::make_unique<Value>();
    out->type = Value::Type::Object;
    skipWhitespace(c);
    if (c.peek() == '}') { c.next(); return true; }
    for (;;) {
        skipWhitespace(c);
        std::string key;
        if (!parseString(c, key, err)) return false;
        for (auto& m : out->obj)
            if (m.key == key) { err = c.pos() + ": duplicate key '" + key + "'"; return false; }
        skipWhitespace(c);
        if (c.next() != ':') { err = c.pos() + ": expected ':'"; return false; }
        skipWhitespace(c);
        ValuePtr child;
        if (!parseValue(c, child, err)) return false;
        out->obj.push_back(Member{std::move(key), std::move(child)});
        skipWhitespace(c);
        char ch = c.next();
        if (ch == ',') continue;
        if (ch == '}') return true;
        err = c.pos() + ": expected ',' or '}'";
        return false;
    }
}

bool parseArray(Cursor& c, ValuePtr& out, std::string& err) {
    c.next(); // '['
    out = std::make_unique<Value>();
    out->type = Value::Type::Array;
    skipWhitespace(c);
    if (c.peek() == ']') { c.next(); return true; }
    for (;;) {
        skipWhitespace(c);
        ValuePtr child;
        if (!parseValue(c, child, err)) return false;
        out->arr.push_back(Elem{std::move(child)});
        skipWhitespace(c);
        char ch = c.next();
        if (ch == ',') continue;
        if (ch == ']') return true;
        err = c.pos() + ": expected ',' or ']'";
        return false;
    }
}

bool parseValue(Cursor& c, ValuePtr& out, std::string& err) {
    skipWhitespace(c);
    if (c.eof()) { err = c.pos() + ": unexpected end of input"; return false; }
    char ch = c.peek();
    if (ch == '{') return parseObject(c, out, err);
    if (ch == '[') return parseArray(c, out, err);
    if (ch == '"') {
        out = std::make_unique<Value>();
        out->type = Value::Type::String;
        return parseString(c, out->str, err);
    }
    if (ch == 't') {
        if (c.end - c.p >= 4 && c.p[0] == 't' && c.p[1] == 'r' && c.p[2] == 'u' && c.p[3] == 'e') {
            c.next(); c.next(); c.next(); c.next();
            out = std::make_unique<Value>();
            out->type = Value::Type::Bool;
            out->b = true;
            return true;
        }
        err = c.pos() + ": bad literal"; return false;
    }
    if (ch == 'f') {
        if (c.end - c.p >= 5 && c.p[0] == 'f' && c.p[1] == 'a' && c.p[2] == 'l' && c.p[3] == 's' && c.p[4] == 'e') {
            for (int i = 0; i < 5; ++i) c.next();
            out = std::make_unique<Value>();
            out->type = Value::Type::Bool;
            out->b = false;
            return true;
        }
        err = c.pos() + ": bad literal"; return false;
    }
    if (ch == 'n') {
        if (c.end - c.p >= 4 && c.p[0] == 'n' && c.p[1] == 'u' && c.p[2] == 'l' && c.p[3] == 'l') {
            for (int i = 0; i < 4; ++i) c.next();
            out = std::make_unique<Value>();
            out->type = Value::Type::Null;
            return true;
        }
        err = c.pos() + ": bad literal"; return false;
    }
    if (ch == '-' || (ch >= '0' && ch <= '9')) {
        out = std::make_unique<Value>();
        out->type = Value::Type::Number;
        return parseNumber(c, out->num, err);
    }
    err = c.pos() + ": unexpected character";
    return false;
}

} // namespace

ParseResult parse(const std::string& source) noexcept {
    ParseResult r;
    try {
        Cursor c(source);
        std::string err;
        if (!parseValue(c, r.value, err)) { r.error = err; r.value = nullptr; return r; }
        skipWhitespace(c);
        if (!c.eof()) { r.error = c.pos() + ": trailing content after JSON document"; r.value = nullptr; return r; }
    } catch (const std::bad_alloc&) {
        r.error = "out of memory";
        r.value = nullptr;
    } catch (...) {
        r.error = "internal parse error";
        r.value = nullptr;
    }
    return r;
}

} // namespace mc::json
