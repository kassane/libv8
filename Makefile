# GNU Make wrapper around scripts/*.sh — provided for users without `just`.
# All real logic lives in scripts/; this file is just thin aliases.

TARGET  ?=
PROFILE ?= default

.PHONY: help fetch build package all clean clean-all check-version version

help:
	@echo "Targets:"
	@echo "  make fetch                       Sync V8 source"
	@echo "  make build [TARGET=…] [PROFILE=…]  Build libv8_monolith"
	@echo "  make package [TARGET=…] [PROFILE=…]  Archive into ./dist/"
	@echo "  make all [TARGET=…] [PROFILE=…]    fetch + build + package"
	@echo "  make clean                       Remove build outputs"
	@echo "  make clean-all                   Also drop V8 checkout"
	@echo "  make check-version               Compare VERSION to upstream"
	@echo ""
	@echo "TARGET = <os>-<arch>  (e.g. linux-x64, macos-arm64, windows-x64)"
	@echo "PROFILE = default | pointer-compression | sandbox | i18n"

fetch:
	./scripts/fetch.sh

build:
	./scripts/build.sh $(TARGET) $(PROFILE)

package:
	./scripts/package.sh $(TARGET) $(PROFILE)

all: fetch build package

clean:
	./scripts/clean.sh

clean-all:
	./scripts/clean.sh --all

check-version:
	./scripts/check-version.sh

version:
	@cat VERSION
