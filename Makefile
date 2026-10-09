SWIFT   := swiftc
BRIDGE  := Sources/Bridge/MouseCapeBridge.h
CORE    := $(wildcard Sources/Core/*.swift)
APPSRC  := $(wildcard Sources/App/*.swift)
BUILD   := build
APP     := MouseCape.app
FLAGS   := -O -import-objc-header $(BRIDGE) \
           -framework AppKit -framework CoreGraphics \
           -framework ApplicationServices -framework ImageIO

.PHONY: all cli app run clean
all: cli app

# ---- command line tool -------------------------------------------------
cli: $(BUILD)/mousecape
$(BUILD)/mousecape: $(CORE) Sources/CLI/main.swift $(BRIDGE)
	@mkdir -p $(BUILD)
	$(SWIFT) $(FLAGS) -o $@ $(CORE) Sources/CLI/main.swift

# ---- app bundle --------------------------------------------------------
app: $(APP)/Contents/MacOS/MouseCapeRevamp
$(APP)/Contents/MacOS/MouseCapeRevamp: $(CORE) $(APPSRC) $(BRIDGE) Resources/Info.plist
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(SWIFT) $(FLAGS) -parse-as-library -o $@ $(CORE) $(APPSRC)
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP) 2>/dev/null || true
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf $(BUILD) $(APP)
