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

// aligned_alloc was added to the Android C library at API 28. WebKit's
// bmalloc DebugHeap uses the C11 spelling, while Bun's Android target stays
// on API 24. Keep the allocation contract and provide the older Bionic
// equivalent through the versioned toolchain header.
#if defined(__ANDROID_API__) && __ANDROID_API__ < 28
#include <stddef.h>
#include <stdlib.h>
static inline void* bun_android_aligned_alloc(size_t alignment, size_t size)
{
    void* result = NULL;
    if (posix_memalign(&result, alignment, size) != 0)
        return NULL;
    return result;
}
#ifndef aligned_alloc
#define aligned_alloc bun_android_aligned_alloc
#endif

// pthread_getname_np is unavailable before API 26. libpas only uses this
// call for optional diagnostics, so return the same failure path as an
// unavailable thread-name query.
#if defined(__ANDROID_API__) && __ANDROID_API__ < 26
#include <pthread.h>
static inline int bun_android_pthread_getname_np(pthread_t, char*, size_t)
{
    return -1;
}
#define pthread_getname_np bun_android_pthread_getname_np
#endif
#endif
