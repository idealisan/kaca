# kaca — 跨平台步骤记录器
# 当前完整实现: macOS。Windows/Linux 仅为遵循同一抽象接口的桩。
CC      := clang
APP     := kaca
SRC     := src
BUILD   := build

# macOS 需要的框架
FRAME   := -framework ApplicationServices -framework CoreGraphics \
           -framework CoreFoundation -framework Cocoa -framework Carbon \
           -framework IOKit -framework Security -framework CoreText \
           -framework UniformTypeIdentifiers

# 目标至少为 macOS 11（用到 NSApplication / UniformTypeIdentifiers 等）
MINVER  := -mmacosx-version-min=11.0

CFLAGS  := -std=c11 -Wall -Wextra -O2 $(MINVER) -I$(SRC) -fobjc-arc

# .app 打包相关
APP_BUNDLE := kaca.app
BUNDLE_BIN := $(APP_BUNDLE)/Contents/MacOS
BUNDLE_RES := $(APP_BUNDLE)/Contents/Resources
ICONSET    := resources/AppIcon.iconset
ICNS       := resources/AppIcon.icns

# 编译进来的源文件（按平台选择）
OBJS := $(BUILD)/main.o \
        $(BUILD)/recorder.o \
        $(BUILD)/base64.o \
        $(BUILD)/macos_capture.o \
        $(BUILD)/macos_toolbar.o

all: $(BUILD)/$(APP)

# 打包成 Mac 上的 .app（而非命令行工具）
app: $(BUILD)/$(APP) $(ICNS)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(BUNDLE_BIN) $(BUNDLE_RES)
	cp $(BUILD)/$(APP) $(BUNDLE_BIN)/$(APP)
	cp resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE_RES)/AppIcon.icns
	# 临时签名（无开发者证书），仅本机可运行
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "已生成 $(APP_BUNDLE)"

$(BUILD)/$(APP): $(OBJS)
	$(CC) $(OBJS) $(FRAME) $(MINVER) -o $@

$(BUILD)/main.o: $(SRC)/main.c $(SRC)/recorder.h $(SRC)/os/os_api.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/recorder.o: $(SRC)/recorder.c $(SRC)/recorder.h $(SRC)/os/os_api.h $(SRC)/base64.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/base64.o: $(SRC)/base64.c $(SRC)/base64.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/macos_capture.o: $(SRC)/os/macos/macos_capture.m $(SRC)/os/os_api.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/macos_toolbar.o: $(SRC)/os/macos/macos_toolbar.m $(SRC)/os/os_api.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# 占位图标：纯标准库 PNG 编码 → iconutil 转 icns
$(ICNS): scripts/make_appicon.py
	python3 scripts/make_appicon.py

$(BUILD):
	mkdir -p $(BUILD)

# 无界面自测：只编译公共逻辑 + 桩 OS 调用，验证滚动分组 / 相对时间 / HTML 生成
TEST_BIN := $(BUILD)/kaca_test
test: $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): $(SRC)/recorder.c $(SRC)/base64.c tests/recorder_test.c \
             $(SRC)/os/os_api.h $(SRC)/recorder.h $(SRC)/base64.h | $(BUILD)
	$(CC) -std=c11 -Wall -I$(SRC) $(SRC)/recorder.c $(SRC)/base64.c tests/recorder_test.c -o $@

clean:
	rm -rf $(BUILD) $(APP_BUNDLE)

.PHONY: all clean test app
