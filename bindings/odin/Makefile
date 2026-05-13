SHELL := /bin/sh

# Workspace root is two levels up from bindings/odin/.
WORKSPACE      := ../..
SDK_KIT_TARGET := $(WORKSPACE)/target/debug

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  LIB_FILE      := libturso_sdk_kit.dylib
  LIB_SYNC_FILE := libturso_sync_sdk_kit.dylib
  RPATH         := @loader_path/../../target/debug
endif
ifeq ($(UNAME),Linux)
  LIB_FILE      := libturso_sdk_kit.so
  LIB_SYNC_FILE := libturso_sync_sdk_kit.so
  RPATH         := $$ORIGIN/../../target/debug
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

.PHONY: help sdk-kit sync-sdk-kit check test sync-test example examples clean

help:
	@echo "Targets:"
	@echo "  sdk-kit       Build the local-DB C ABI library (debug profile) via cargo"
	@echo "  sync-sdk-kit  Build the sync-engine C ABI library (debug profile) via cargo"
	@echo "  check         odin check on turso, sync, tests, every example dir"
	@echo "  test          Build and run the local-DB test runner"
	@echo "  sync-test     Build and run the sync test runner"
	@echo "  example       Run the minimal example"
	@echo "  examples      Run every example"
	@echo "  clean         Remove odin build outputs"

sdk-kit:
	cd $(WORKSPACE) && cargo build -p turso_sdk_kit
	@test -f $(SDK_KIT_TARGET)/$(LIB_FILE) || (echo "missing $(LIB_FILE) in $(SDK_KIT_TARGET)" && exit 1)

sync-sdk-kit:
	cd $(WORKSPACE) && cargo build -p turso_sync_sdk_kit
	@test -f $(SDK_KIT_TARGET)/$(LIB_SYNC_FILE) || (echo "missing $(LIB_SYNC_FILE) in $(SDK_KIT_TARGET)" && exit 1)

check:
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

example: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin

examples: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin
	odin run examples/named_params $(ODIN_FLAGS) -out:named_params.bin

clean:
	rm -f *.bin tests/*.bin tests/sync/*.bin examples/*/*.bin
