#include "os/os_api.h"
#include "recorder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* 调试开关：--no-dialog 跳过保存对话框；--out <path> 直接保存到指定路径 */
static int   g_no_dialog = 0;
static const char *g_out_path = NULL;

static void on_start(void) {
    recorder_start();
    os_set_recording_state(1);
    if (os_start_capture(recorder_handle_event, NULL) != 0) {
        recorder_stop();
        os_set_recording_state(0);
        os_open_accessibility_settings();
        fprintf(stderr, "事件捕获启动失败：请在本机「系统设置 → 隐私与安全性 → 辅助功能」中启用 kaca，然后重新点击「开始录制」。\n");
    }
}

static void on_stop(void) {
    os_stop_capture();
    recorder_stop();
    os_set_recording_state(0);
}

static void on_save(void) {
    const char *path = NULL;
    char *dlg = NULL;

    if (!g_no_dialog)
        dlg = os_show_save_dialog("step-report.html");

    if (dlg) {
        path = recorder_save_to(dlg);          /* 用户选择的路径 */
    } else if (g_out_path) {
        path = recorder_save_to(g_out_path);   /* 调试：--out 指定 */
    } else if (g_no_dialog) {
        path = recorder_save_default();        /* 调试：默认路径 */
    }
    /* dlg==NULL 且非调试模式：说明用户在对话框里取消了，不保存 */

    if (path) printf("报告已保存: %s\n", path);
    else      fprintf(stderr, "保存失败\n");
    free(dlg);
}

static void on_settings(void) {
    os_toggle_capture_mode();
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-dialog") == 0)      g_no_dialog = 1;
        else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) g_out_path = argv[++i];
    }

    if (os_init() != 0) {
        fprintf(stderr, "初始化失败\n");
        return 1;
    }
    if (!os_ensure_permissions()) {
        fprintf(stderr, "提示：未检测到辅助功能授权。工具条已启动，开始录制前请在系统设置中授权 kaca。\n");
    }

    recorder_init();
    os_set_tick_callback(recorder_elapsed);
    os_show_toolbar(on_start, on_stop, on_save, on_settings);

    recorder_free();
    os_shutdown();
    return 0;
}
