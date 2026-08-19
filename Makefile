PLUGIN_ID := do1mj.qrz
PLUGIN_NAME := QRZ
SRC := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DEST := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)
BINDINGS := $(HOME)/.config/hypr/bindings.lua
BIND_KEY ?= SUPER + CTRL + SHIFT + Q
BIND_BEGIN := -- do1mj.qrz begin
BIND_END := -- do1mj.qrz end

.PHONY: all build compile validate install run uninstall delete clean help

all: validate

help:
	@echo "Targets: build compile validate install run uninstall delete clean"

build compile: validate
	@echo "QML plugin; nothing to compile"

validate:
	@omarchy plugin validate "$(SRC)"

install: validate
	@mkdir -p "$(DEST)/scripts"
	@rm -f "$(DEST)/QrzWebEngine.qml" "$(DEST)/QrzHtmlFallback.qml" "$(DEST)/QrzPage.js" "$(DEST)/QrzResult.qml"
	@install -m 644 "$(SRC)/manifest.json" "$(SRC)/Overlay.qml" "$(SRC)/BarWidget.qml" \
		"$(SRC)/README.md" "$(SRC)/LICENSE" "$(DEST)/"
	@install -m 755 "$(SRC)/scripts/qrz-lookup.py" "$(SRC)/scripts/qrz-xml.py" "$(SRC)/scripts/hypr-bind.py" "$(DEST)/scripts/"
	@omarchy-shell shell rescanPlugins
	@-omarchy plugin disable "$(PLUGIN_ID)" >/dev/null 2>&1
	@omarchy plugin enable "$(PLUGIN_ID)" --section right
	@$(MAKE) --no-print-directory bind
	@echo "Installed $(PLUGIN_ID) to $(DEST)"

bind:
	@python3 "$(SRC)/scripts/hypr-bind.py" bind "$(BINDINGS)" "$(BIND_BEGIN)" "$(BIND_END)" "$(BIND_KEY)" "$(PLUGIN_ID)"
	@-hyprctl reload >/dev/null 2>&1 || true

unbind:
	@python3 "$(SRC)/scripts/hypr-bind.py" unbind "$(BINDINGS)" "$(BIND_BEGIN)" "$(BIND_END)"
	@-hyprctl reload >/dev/null 2>&1 || true

run: install
	@omarchy-shell shell toggle "$(PLUGIN_ID)" '{}'

uninstall delete:
	@-omarchy plugin disable "$(PLUGIN_ID)"
	@$(MAKE) --no-print-directory unbind
	@if [ "$(SRC)" != "$(DEST)" ] && [ -e "$(DEST)" ]; then rm -rf "$(DEST)"; fi
	@if [ "$(SRC)" = "$(DEST)" ]; then echo "Source lives at $(DEST); left files in place after disable"; fi
	@-omarchy-shell shell rescanPlugins
	@echo "Removed $(PLUGIN_ID)"

clean:
	@rm -rf "$(SRC)/__pycache__" "$(SRC)/scripts/__pycache__"
