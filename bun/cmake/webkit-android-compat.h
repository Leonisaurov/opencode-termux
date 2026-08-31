#pragma once

// Android's Bionic libc does not expose the legacy BSD bcmp symbol used by
// WebKit's portable allocator code. Keep the WebKit checkout untouched while
// providing the equivalent operation from the root-owned Android toolchain
// contract.
#if defined(__ANDROID__)
#include <string.h>
#ifndef bcmp
#define bcmp(first, second, size) memcmp((first), (second), (size))
#endif
#endif
