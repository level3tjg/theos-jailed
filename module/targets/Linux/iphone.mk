TARGET_CODESIGN := $(_THEOS_FALSE)
TARGET_INSTALL_REMOTE := $(_THEOS_FALSE)
_THEOS_TARGET_DEFAULT_PACKAGE_FORMAT := ipa-jailed
$(TWEAK_NAME)_INSTALL := 0
THEOS_JAILED_PATH := $(THEOS_MODULE_PATH)/jailed
THEOS_JAILED_BIN := $(THEOS_JAILED_PATH)/bin
export INSERT_DYLIB := $(THEOS_JAILED_BIN)/insert_dylib_linux
export INSTALL_NAME_TOOL := $(wildcard /usr/lib/llvm-*/bin/llvm-install-name-tool)