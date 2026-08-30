register_repository(
  NAME
    lolhtml
  REPOSITORY
    cloudflare/lol-html
  COMMIT
    67f1d4ffd6b74db7e053fb129dcce620193c180d
)

set(LOLHTML_CWD ${VENDOR_PATH}/lolhtml/c-api)
set(LOLHTML_BUILD_PATH ${BUILD_PATH}/lolhtml)

if(DEBUG)
  set(LOLHTML_BUILD_TYPE debug)
else()
  set(LOLHTML_BUILD_TYPE release)
endif()

set(LOLHTML_LIBRARY ${LOLHTML_BUILD_PATH}/${LOLHTML_BUILD_TYPE}/${CMAKE_STATIC_LIBRARY_PREFIX}lolhtml${CMAKE_STATIC_LIBRARY_SUFFIX})

set(LOLHTML_BUILD_ARGS
  --target-dir ${BUILD_PATH}/lolhtml
)

if(RELEASE)
  list(APPEND LOLHTML_BUILD_ARGS --release)
endif()

# Android cross-compilation: target the Android NDK toolchain
if(ANDROID)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(LOLHTML_RUST_TARGET "aarch64-linux-android")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    set(LOLHTML_RUST_TARGET "x86_64-linux-android")
  else()
    message(FATAL_ERROR "Unsupported Android architecture for LolHtml: ${CMAKE_SYSTEM_PROCESSOR}")
  endif()
  list(APPEND LOLHTML_BUILD_ARGS --target ${LOLHTML_RUST_TARGET})
  # Update library path to include the target triple subdirectory
  set(LOLHTML_LIBRARY ${LOLHTML_BUILD_PATH}/${LOLHTML_RUST_TARGET}/${LOLHTML_BUILD_TYPE}/${CMAKE_STATIC_LIBRARY_PREFIX}lolhtml${CMAKE_STATIC_LIBRARY_SUFFIX})
  # Set the NDK linker for Rust — must use the versioned clang (e.g., aarch64-linux-android24-clang)
  # so the linker automatically targets the correct Android API level and sysroot.
  string(TOUPPER "${LOLHTML_RUST_TARGET}" LOLHTML_RUST_TARGET_UPPER)
  string(REPLACE "-" "_" LOLHTML_RUST_TARGET_UPPER "${LOLHTML_RUST_TARGET_UPPER}")
  get_filename_component(_NDK_BIN_DIR "${CMAKE_C_COMPILER}" DIRECTORY)
  set(LOLHTML_CARGO_LINKER "CARGO_TARGET_${LOLHTML_RUST_TARGET_UPPER}_LINKER=${_NDK_BIN_DIR}/aarch64-linux-android${ANDROID_API_LEVEL}-clang")
endif()

# Windows requires unwind tables, apparently.
if (NOT WIN32)
  # Use RUSTFLAGS (space-separated) instead of CARGO_ENCODED_RUSTFLAGS (requires 0x1F separator which CMake can't encode)
  set(RUSTFLAGS "-Cpanic=abort -Cdebuginfo=0 -Cforce-unwind-tables=no -Copt-level=s")
endif()

set(LOLHTML_ENV
  CARGO_TERM_COLOR=always
  CARGO_TERM_VERBOSE=true
  CARGO_TERM_DIAGNOSTIC=true
  RUSTFLAGS=${RUSTFLAGS}
  CARGO_HOME=${CARGO_HOME}
  RUSTUP_HOME=${RUSTUP_HOME}
)

if(ANDROID AND LOLHTML_CARGO_LINKER)
  list(APPEND LOLHTML_ENV ${LOLHTML_CARGO_LINKER})
endif()

register_command(
  TARGET
    lolhtml
  CWD
    ${LOLHTML_CWD}
  COMMAND
    ${CARGO_EXECUTABLE}
      build
      ${LOLHTML_BUILD_ARGS}
  ARTIFACTS
    ${LOLHTML_LIBRARY}
  ENVIRONMENT
    ${LOLHTML_ENV}
)

target_link_libraries(${bun} PRIVATE ${LOLHTML_LIBRARY})
if(BUN_LINK_ONLY)
  target_sources(${bun} PRIVATE ${LOLHTML_LIBRARY})
endif()
