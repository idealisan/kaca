#include "os/os_api.h"
#include "recorder.h"

#include <stdio.h>

static void on_start(void) {
    recorder_start();
    os_set_recording_state(1);
    if (os_start_capture(recorder_handle_event, NULL) != 0)
        fprintf(stderr, "警告: 事件捕获启动失败（可能未授予辅助功能权限）\n");
}

static void on_stop(void) {
    os_stop_capture();
    recorder_stop();
    os_set_recording_state(0);
}

static void on_save(void) {
    const char *p = recorder_save_default();
    if (p) printf("报告已保存: %s\n", p);
    else   fprintf(stderr, "保存失败\n");
}

static void on_settings(void) {
    os_toggle_capture_mode();
}

int main(void) {
    if (os_init() != 0) {
        fprintf(stderr, "初始化失败\n");
        return 1;
    }
    if (!os_ensure_permissions()) {
        fprintf(stderr, "需要辅助功能权限：请在「系统设置 → 隐私与安全性 → 辅助功能」中授予本程序权限后重试。\n");
        return 1;
    }

    recorder_init();
    os_set_tick_callback(recorder_elapsed);
    os_show_toolbar(on_start, on_stop, on_save, on_settings);

    recorder_free();
    os_shutdown();
    return 0;
}
