# kaca — 跨平台步骤记录器
# 当前完整实现: macOS。Windows/Linux 仅为遵循同一抽象接口的桩。
CC      := clang
APP     := kaca
SRC     := src
BUILD   := build

# macOS 需要的框架
FRAME   := -framework ApplicationServices -framework CoreGraphics \
           -framework CoreFoundation -framework Cocoa -framework Carbon \
           -framework IOKit -framework Security -framework CoreText

CFLAGS  := -std=c11 -Wall -Wextra -O2 -I$(SRC) -fobjc-arc

# 编译进来的源文件（按平台选择）
OBJS := $(BUILD)/main.o \
        $(BUILD)/recorder.o \
        $(BUILD)/base64.o \
        $(BUILD)/macos_capture.o \
        $(BUILD)/macos_toolbar.o

all: $(BUILD)/$(APP)

$(BUILD)/$(APP): $(OBJS)
	$(CC) $(OBJS) $(FRAME) -o $@

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
	rm -rf $(BUILD)

.PHONY: all clean test
