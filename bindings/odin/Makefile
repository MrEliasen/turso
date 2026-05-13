SHELL := /bin/sh

# Workspace root is two levels up from bindings/odin/.
WORKSPACE      := ../..
SDK_KIT_TARGET := $(WORKSPACE)/target/debug

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  LIB_FILE := libturso_sdk_kit.dylib
  RPATH    := @loader_path/../../target/debug
endif
ifeq ($(UNAME),Linux)
  LIB_FILE := libturso_sdk_kit.so
  RPATH    := $$ORIGIN/../../target/debug
endif

# Linker flags: link search path + baked-in rpath so the binary loads the dylib
# from target/debug/ without DYLD_LIBRARY_PATH / LD_LIBRARY_PATH at runtime.
ODIN_LINK_FLAGS := -L$(SDK_KIT_TARGET) -Wl,-rpath,$(RPATH)
ODIN_FLAGS      := -extra-linker-flags:"$(ODIN_LINK_FLAGS)"

.PHONY: help sdk-kit check test example examples clean

help:
	@echo "Targets:"
	@echo "  sdk-kit   Build the C ABI library (debug profile) via cargo"
	@echo "  check     odin check on turso, tests, every example dir"
	@echo "  test      Build and run the test runner"
	@echo "  example   Run the minimal example"
	@echo "  examples  Run every example"
	@echo "  clean     Remove odin build outputs"

sdk-kit:
	cd $(WORKSPACE) && cargo build -p turso_sdk_kit
	@test -f $(SDK_KIT_TARGET)/$(LIB_FILE) || (echo "missing $(LIB_FILE) in $(SDK_KIT_TARGET)" && exit 1)

check:
	odin check turso -no-entry-point
	odin check tests
	odin check examples/minimal
	odin check examples/named_params

test: sdk-kit
	odin run tests $(ODIN_FLAGS) -out:tests.bin

example: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin

examples: sdk-kit
	odin run examples/minimal $(ODIN_FLAGS) -out:minimal.bin
	odin run examples/named_params $(ODIN_FLAGS) -out:named_params.bin

clean:
	rm -f *.bin tests/*.bin examples/*/*.bin
