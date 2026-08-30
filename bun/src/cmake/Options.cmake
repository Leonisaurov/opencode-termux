if(NOT CMAKE_SYSTEM_NAME OR NOT CMAKE_SYSTEM_PROCESSOR)
  message(FATAL_ERROR "CMake included this file before project() was called")
endif()

optionx(BUN_LINK_ONLY BOOL "If only the linking step should be built" DEFAULT OFF)
optionx(BUN_CPP_ONLY BOOL "If only the C++ part of Bun should be built" DEFAULT OFF)

optionx(BUILDKITE BOOL "If Buildkite is enabled" DEFAULT OFF)
optionx(GITHUB_ACTIONS BOOL "If GitHub Actions is enabled" DEFAULT OFF)

if(BUILDKITE)
  optionx(BUILDKITE_COMMIT STRING "The commit hash")
endif()

optionx(CMAKE_BUILD_TYPE "Debug|Release|RelWithDebInfo|MinSizeRel" "The build type to use" REQUIRED)

if(CMAKE_BUILD_TYPE MATCHES "Release|RelWithDebInfo|MinSizeRel")
  setx(RELEASE ON)
else()
  setx(RELEASE OFF)
endif()

if(CMAKE_BUILD_TYPE MATCHES "Debug")
  setx(DEBUG ON)
else()
  setx(DEBUG OFF)
endif()

optionx(BUN_TEST BOOL "Build Bun's unit test suite instead of the normal build" DEFAULT OFF)

if (BUN_TEST)
  setx(TEST ON)
else()
  setx(TEST OFF)
endif()


if(CMAKE_BUILD_TYPE MATCHES "MinSizeRel")
  setx(ENABLE_SMOL ON)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Android")
  # Android uses Bionic libc, but is Linux-kernel based.
  # We treat it as a Linux variant with ABI=android.
  set(LINUX ON)
  set(ANDROID ON)
  setx(OS "linux")
elseif(APPLE)
  setx(OS "darwin")
elseif(WIN32)
  setx(OS "windows")
elseif(LINUX)
  setx(OS "linux")
else()
  message(FATAL_ERROR "Unsupported operating system: ${CMAKE_SYSTEM_NAME}")
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|arm")
  setx(ARCH "aarch64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "amd64|x86_64|x64|AMD64")
  setx(ARCH "x64")
else()
  message(FATAL_ERROR "Unsupported architecture: ${CMAKE_SYSTEM_PROCESSOR}")
endif()

if(LINUX)
  if(ANDROID)
    set(DEFAULT_ABI "android")
    optionx(ABI "android" "The ABI to use (android for Bionic libc)" DEFAULT ${DEFAULT_ABI})
  else()
    if(EXISTS "/etc/alpine-release")
      set(DEFAULT_ABI "musl")
    else()
      set(DEFAULT_ABI "gnu")
    endif()
    optionx(ABI "musl|gnu" "The ABI to use (e.g. musl, gnu)" DEFAULT ${DEFAULT_ABI})
  endif()
endif()

if(ARCH STREQUAL "x64")
  optionx(ENABLE_BASELINE BOOL "If baseline features should be used for older CPUs (e.g. disables AVX, AVX2)" DEFAULT OFF)
endif()

# Disabling logs by default for tests yields faster builds
if (DEBUG AND NOT TEST)
  set(DEFAULT_ENABLE_LOGS ON)
else()
  set(DEFAULT_ENABLE_LOGS OFF)
endif()

optionx(ENABLE_LOGS BOOL "If debug logs should be enabled" DEFAULT ${DEFAULT_ENABLE_LOGS})
optionx(ENABLE_ASSERTIONS BOOL "If debug assertions should be enabled" DEFAULT ${DEBUG})

optionx(ENABLE_CANARY BOOL "If canary features should be enabled" DEFAULT ON)

if(ENABLE_CANARY)
  set(DEFAULT_CANARY_REVISION "1")
else()
  set(DEFAULT_CANARY_REVISION "0")
endif()

optionx(CANARY_REVISION STRING "The canary revision of the build" DEFAULT ${DEFAULT_CANARY_REVISION})

if(LINUX)
  optionx(ENABLE_VALGRIND BOOL "If Valgrind support should be enabled" DEFAULT OFF)
endif()

if(DEBUG AND APPLE AND ARCH STREQUAL "aarch64")
  set(DEFAULT_ASAN ON)
else()
  set(DEFAULT_ASAN OFF)
endif()

optionx(ENABLE_ASAN BOOL "If ASAN support should be enabled" DEFAULT ${DEFAULT_ASAN})

if(RELEASE AND LINUX AND CI AND NOT ENABLE_ASSERTIONS AND NOT ENABLE_ASAN)
  set(DEFAULT_LTO ON)
else()
  set(DEFAULT_LTO OFF)
endif()

optionx(ENABLE_LTO BOOL "If LTO (link-time optimization) should be used" DEFAULT ${DEFAULT_LTO})

if(ENABLE_ASAN AND ENABLE_LTO)
  message(WARNING "ASAN and LTO are not supported together, disabling LTO")
  setx(ENABLE_LTO OFF)
endif()

if(USE_VALGRIND AND NOT USE_BASELINE)
  message(WARNING "If valgrind is enabled, baseline must also be enabled")
  setx(USE_BASELINE ON)
endif()

if(BUILDKITE_COMMIT)
  set(DEFAULT_REVISION ${BUILDKITE_COMMIT})
else()
  execute_process(
    COMMAND git rev-parse HEAD
    WORKING_DIRECTORY ${CWD}
    OUTPUT_VARIABLE DEFAULT_REVISION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(NOT DEFAULT_REVISION AND NOT DEFINED ENV{GIT_SHA} AND NOT DEFINED ENV{GITHUB_SHA})
    set(DEFAULT_REVISION "unknown")
  endif()
endif()

optionx(REVISION STRING "The git revision of the build" DEFAULT ${DEFAULT_REVISION})

# Used in process.version, process.versions.node, napi, and elsewhere
optionx(NODEJS_VERSION STRING "The version of Node.js to report" DEFAULT "22.6.0")

# Used in process.versions.modules and compared while loading V8 modules
optionx(NODEJS_ABI_VERSION STRING "The ABI version of Node.js to report" DEFAULT "127")

if(APPLE)
  set(DEFAULT_STATIC_SQLITE OFF)
else()
  set(DEFAULT_STATIC_SQLITE ON)
endif()

optionx(USE_STATIC_SQLITE BOOL "If SQLite should be statically linked" DEFAULT ${DEFAULT_STATIC_SQLITE})

set(DEFAULT_STATIC_LIBATOMIC ON)

if(CMAKE_HOST_LINUX AND NOT WIN32 AND NOT APPLE AND NOT ANDROID)
  execute_process(
    COMMAND grep -w "NAME" /etc/os-release
    OUTPUT_VARIABLE LINUX_DISTRO
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(LINUX_DISTRO MATCHES "NAME=\"(Arch|Manjaro|Artix) Linux( ARM)?\"|NAME=\"openSUSE Tumbleweed\"")
    set(DEFAULT_STATIC_LIBATOMIC OFF)
  endif()
endif()

optionx(USE_STATIC_LIBATOMIC BOOL "If libatomic should be statically linked" DEFAULT ${DEFAULT_STATIC_LIBATOMIC})

if(APPLE)
  set(DEFAULT_WEBKIT_ICU OFF)
else()
  set(DEFAULT_WEBKIT_ICU ON)
endif()

optionx(USE_WEBKIT_ICU BOOL "Use the ICU libraries from WebKit" DEFAULT ${DEFAULT_WEBKIT_ICU})

optionx(ERROR_LIMIT STRING "Maximum number of errors to show when compiling C++ code" DEFAULT "100")

list(APPEND CMAKE_ARGS -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)

# Android: Now that project() has been called, the toolchain file has been processed
# and all NDK variables (CMAKE_C_COMPILER, CMAKE_SYSROOT, etc.) are available.
# Populate CMAKE_ARGS so that dependency sub-builds also use the NDK compilers.
if(ANDROID AND ANDROID_DEFER_CMAKE_ARGS)
  message(STATUS "Android: Propagating NDK compilers to dependency sub-builds")
  message(STATUS "  CMAKE_C_COMPILER: ${CMAKE_C_COMPILER}")
  message(STATUS "  CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}")
  message(STATUS "  CMAKE_SYSROOT: ${CMAKE_SYSROOT}")
  list(APPEND CMAKE_ARGS
    -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
    -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
    -DCMAKE_AR=${CMAKE_AR}
    -DCMAKE_RANLIB=${CMAKE_RANLIB}
    -DCMAKE_STRIP=${CMAKE_STRIP}
    -DCMAKE_SYSTEM_NAME=Android
    -DCMAKE_SYSTEM_VERSION=${CMAKE_SYSTEM_VERSION}
    -DCMAKE_ANDROID_ARCH_ABI=${CMAKE_ANDROID_ARCH_ABI}
    -DCMAKE_SYSROOT=${CMAKE_SYSROOT}
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  )
  if(CMAKE_ANDROID_NDK)
    list(APPEND CMAKE_ARGS -DCMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK})
  elseif(ANDROID_NDK_HOME)
    list(APPEND CMAKE_ARGS -DCMAKE_ANDROID_NDK=${ANDROID_NDK_HOME})
  endif()
endif()
