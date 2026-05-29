SHELL := /bin/sh

# Workspace root is two levels up from bindings/odin/.
WORKSPACE      := ../..
SDK_KIT_TARGET := $(WORKSPACE)/target/debug

# Release-profile output. Used by the *-release targets below for downstream
# users who want a tuned binding (the on-repo dev workflow uses debug per
# CLAUDE.md; release is for shipping).
SDK_KIT_TARGET_RELEASE := $(WORKSPACE)/target/release

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  LIB_FILE      := libturso_sdk_kit.dylib
  LIB_SYNC_FILE := libturso_sync_sdk_kit.dylib
  RPATH         := @loader_path/../../target/debug
  RPATH_RELEASE := @loader_path/../../target/release
endif
ifeq ($(UNAME),Linux)
  LIB_FILE      := libturso_sdk_kit.so
  LIB_SYNC_FILE := libturso_sync_sdk_kit.so
  RPATH         := $$ORIGIN/../../target/debug
  RPATH_RELEASE := $$ORIGIN/../../target/release
endif

# Linker flags: link search path + baked-in rpath so the binary loads the dylib
# from target/debug/ without DYLD_LIBRARY_PATH / LD_LIBRARY_PATH at runtime.
ODIN_LINK_FLAGS := -L$(SDK_KIT_TARGET) -Wl,-rpath,$(RPATH)
ODIN_FLAGS      := -extra-linker-flags:"$(ODIN_LINK_FLAGS)"

# Sync test binary: routes the parent turso/raw foreign import at
# libturso_sync_sdk_kit via -define:TURSO_USE_SYNC_DYLIB=true, so the binary
# links only ONE dylib. The sync dylib re-exports every core turso_* symbol,
# so this keeps allocator/global state on a single memory namespace. Linking
# both libs would split turso_core state and crash on cross-lib pointer use.
ODIN_SYNC_FLAGS := $(ODIN_FLAGS) -define:TURSO_USE_SYNC_DYLIB=true

.PHONY: help sdk-kit sdk-kit-release sync-sdk-kit sync-sdk-kit-release check check-abi test sync-test stress-test tsan-test asan-test example examples clean

# Path to the C ABI header the hand-written FFI (turso/raw/imports.odin)
# mirrors, plus the pinned checksum recorded under abi/.
TURSO_HEADER     := $(WORKSPACE)/sdk-kit/turso.h
TURSO_HEADER_SHA := abi/turso.h.sha256

help:
	@echo "Targets:"
	@echo "  sdk-kit               Build the local-DB C ABI library (debug profile) via cargo"
	@echo "  sdk-kit-release       Build the local-DB C ABI library (release profile, --release) via cargo"
	@echo "  sync-sdk-kit          Build the sync-engine C ABI library (debug profile) via cargo"
	@echo "  sync-sdk-kit-release  Build the sync-engine C ABI library (release profile) via cargo"
	@echo "  check-abi             Fail if sdk-kit/turso.h drifted from the pinned checksum (run first by check)"
	@echo "  check                 check-abi, then odin check on turso, sync, tests, every example dir"
	@echo "  test                  Build and run the local-DB test runner"
	@echo "  sync-test             Build and run the sync test runner"
	@echo "  stress-test           Build and run the test binary with the long iteration count"
	@echo "                        (TURSO_TSAN_STRESS=true). Catches gross concurrency failures"
	@echo "                        without the ThreadSanitizer slowdown."
	@echo "  tsan-test             Same as stress-test plus -sanitize:thread. Race reports"
	@echo "                        exit non-zero. Intended for nightly or workflow_dispatch CI."
	@echo "  asan-test             Local-DB suite under -sanitize:address (Linux CI; macOS has a"
	@echo "                        known clang_rt version skew - see the target comment)."
	@echo "  example               Run the minimal example"
	@echo "  examples              Run every example"
	@echo "  clean                 Remove odin build outputs"

sdk-kit:
	cd $(WORKSPACE) && cargo build -p turso_sdk_kit
	@test -f $(SDK_KIT_TARGET)/$(LIB_FILE) || (echo "missing $(LIB_FILE) in $(SDK_KIT_TARGET)" && exit 1)

# Release builds are intended for downstream packaging; in-repo development
# uses the debug profile per workspace CLAUDE.md. The resulting dylib lives at
# $(SDK_KIT_TARGET_RELEASE), which requires a different rpath; users who switch
# profiles should rebuild any Odin binary against the matching target/ path.
sdk-kit-release:
	cd $(WORKSPACE) && cargo build -p turso_sdk_kit --release
	@test -f $(SDK_KIT_TARGET_RELEASE)/$(LIB_FILE) || (echo "missing $(LIB_FILE) in $(SDK_KIT_TARGET_RELEASE)" && exit 1)

sync-sdk-kit:
	cd $(WORKSPACE) && cargo build -p turso_sync_sdk_kit
	@test -f $(SDK_KIT_TARGET)/$(LIB_SYNC_FILE) || (echo "missing $(LIB_SYNC_FILE) in $(SDK_KIT_TARGET)" && exit 1)

sync-sdk-kit-release:
	cd $(WORKSPACE) && cargo build -p turso_sync_sdk_kit --release
	@test -f $(SDK_KIT_TARGET_RELEASE)/$(LIB_SYNC_FILE) || (echo "missing $(LIB_SYNC_FILE) in $(SDK_KIT_TARGET_RELEASE)" && exit 1)

# check-abi guards against silent FFI drift. turso/raw/imports.odin is a
# hand-written 1:1 mirror of sdk-kit/turso.h with no codegen; if the header
# changes and imports.odin is not updated to match, every call across the FFI
# is undefined behaviour. We pin the header's SHA-256 in abi/turso.h.sha256 and
# fail loudly when the live header no longer matches. The maintainer must then
# diff the header, reconcile turso/raw/imports.odin (signatures, structs, enums,
# and the #assert layout pins), and re-pin via:
#   (cd $(WORKSPACE) && shasum -a 256 sdk-kit/turso.h) > bindings/odin/$(TURSO_HEADER_SHA)
check-abi:
	@test -f "$(TURSO_HEADER)" || { echo "ABI CHECK FAILED: header not found at $(TURSO_HEADER)"; exit 1; }
	@test -f "$(TURSO_HEADER_SHA)" || { echo "ABI CHECK FAILED: pinned checksum not found at $(TURSO_HEADER_SHA)"; exit 1; }
	@pinned=`awk '{print $$1; exit}' "$(TURSO_HEADER_SHA)"`; \
	actual=`shasum -a 256 "$(TURSO_HEADER)" | awk '{print $$1}'`; \
	if [ "$$pinned" != "$$actual" ]; then \
		echo "================================================================"; \
		echo "ABI CHECK FAILED: sdk-kit/turso.h has drifted from the pinned hash."; \
		echo "  pinned: $$pinned"; \
		echo "  actual: $$actual"; \
		echo ""; \
		echo "The hand-written FFI in turso/raw/imports.odin mirrors turso.h 1:1"; \
		echo "and is NOT regenerated. Re-verify imports.odin against the new"; \
		echo "header (proc signatures, struct fields + #assert layout pins, enums),"; \
		echo "then re-pin the checksum with:"; \
		echo "  (cd $(WORKSPACE) && shasum -a 256 sdk-kit/turso.h) > bindings/odin/$(TURSO_HEADER_SHA)"; \
		echo "================================================================"; \
		exit 1; \
	fi
	@echo "ABI check OK: sdk-kit/turso.h matches the pinned checksum."

check: check-abi
	odin check turso -no-entry-point
	odin check turso/sync -no-entry-point -define:TURSO_USE_SYNC_DYLIB=true
	odin check turso/sync/curlhttp -no-entry-point -define:TURSO_USE_SYNC_DYLIB=true
	odin check tests
	odin check tests/sync -define:TURSO_USE_SYNC_DYLIB=true
	odin check examples/minimal
	odin check examples/named_params

test: sdk-kit
	odin run tests $(ODIN_FLAGS) -out:tests.bin

sync-test: sync-sdk-kit
	odin run tests/sync $(ODIN_SYNC_FLAGS) -out:sync_tests.bin

# stress-test reuses the regular test binary but flips on the long iteration
# count for setup_seqlock_stress (and any future stress-shaped tests). No
# sanitizer overhead - intended as a "before you push, run this once" check.
stress-test: sdk-kit
	odin run tests $(ODIN_FLAGS) -define:TURSO_TSAN_STRESS=true -out:stress_tests.bin

# tsan-test builds the same binary with ThreadSanitizer. A torn read of
# g_setup_ctx or an unsynchronised access to g_logger triggers a
# "WARNING: ThreadSanitizer: data race" line and a non-zero exit. Intended
# for nightly or workflow_dispatch CI; on a developer laptop it takes ~5-15x
# longer than `make test`.
tsan-test: sdk-kit
	odin run tests $(ODIN_FLAGS) -sanitize:thread -define:TURSO_TSAN_STRESS=true -out:tsan_tests.bin

# asan-test builds the local-DB suite with AddressSanitizer (heap overflow,
# use-after-free, double-free at the binding boundary). Intended for Linux CI,
# where Odin's bundled-LLVM ASan ABI matches the system clang_rt. On macOS the
# link currently fails with an `___asan_version_mismatch_check_v*` undefined
# symbol because Apple's clang_rt version skews from Odin's LLVM; rely on TSan
# plus the leak-tracking allocator (always on in `make test`) for local runs.
asan-test: sdk-kit
	odin run tests $(ODIN_FLAGS) -sanitize:address -out:asan_tests.bin

example: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin

examples: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin
	odin run examples/named_params $(ODIN_FLAGS) -out:named_params.bin

clean:
	rm -f *.bin tests/*.bin tests/sync/*.bin examples/*/*.bin stress_tests.bin tsan_tests.bin
