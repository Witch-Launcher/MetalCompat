// Diagnostics singleton implementation.
#include "Diag.hpp"

namespace mc::diag {

Diagnostics& global() noexcept {
    static Diagnostics instance;
    return instance;
}

} // namespace mc::diag
