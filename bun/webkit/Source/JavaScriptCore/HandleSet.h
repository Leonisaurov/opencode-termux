// Compatibility header for Bun's JSC bindings.
//
// The current WebKit source no longer exports this legacy header, while the
// pinned Bun source still includes it from its common binding root. Bun does
// not use any declarations from the header, so keep the include source-level
// and intentionally empty rather than inventing an obsolete JSC API.
#pragma once
