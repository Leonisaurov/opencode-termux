#ifndef WIN32

#include <signal.h>

#ifdef __ANDROID__
// Android Bionic does not have posix_spawnattr_setsigdefault/posix_spawnattr_setsigmask
// at API level 24. Since Bun uses its own custom posix_spawn_bun() on Linux/Android
// which handles signals directly, this function is a no-op stub.
#include <spawn.h>
extern "C" int posix_spawnattr_reset_signals(posix_spawnattr_t* attr)
{
    (void)attr;
    return 0;
}
#else
#include <spawn.h>

extern "C" int posix_spawnattr_reset_signals(posix_spawnattr_t* attr)
{
    sigset_t signal_set;
    sigfillset(&signal_set);
    if (posix_spawnattr_setsigdefault(attr, &signal_set) != 0) {
        return 1;
    }

    sigemptyset(&signal_set);
    if (posix_spawnattr_setsigmask(attr, &signal_set) != 0) {
        return 1;
    }

    return 0;
}
#endif

#endif
