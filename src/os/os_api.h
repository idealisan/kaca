#ifndef OS_API_H
#define OS_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 平台标识 */
typedef enum {
    OS_PLATFORM_MACOS = 0,
    OS_PLATFORM_WINDOWS,
    OS_PLATFORM_LINUX
} os_platform_t;

/* 事件类型 */
typedef enum {
    STEP_EVENT_KEY = 0,
    STEP_EVENT_MOUSE,
    STEP_EVENT_SCROLL
} step_event_kind_t;

/* 鼠标按键 */
#define MOUSE_BTN_LEFT   0
#define MOUSE_BTN_RIGHT  1
#define MOUSE_BTN_MIDDLE 2
#define MOUSE_BTN_OTHER  3

/*
 * 一次原始事件的通用描述。由平台层在事件发生时填充。
 * - 键盘: 填 keycode / key_name
 * - 鼠标: 填 button
 * - 滚动: 填 scroll_dx / scroll_dy（单步原始增量，正负表示方向）
 * - 上下文: 填光标位置与窗口/进程/控件信息
 */
typedef struct {
    step_event_kind_t kind;
    double            timestamp;   /* unix 秒（含小数） */
    int               cursor_x;
    int               cursor_y;

    /* KEY */
    int               keycode;
    char              key_name[64];

    /* MOUSE */
    int               button;

    /* SCROLL（单步原始增量）*/
    int               scroll_dx;   /* 水平: +右 -左 */
    int               scroll_dy;   /* 垂直: +下 -上 */

    /* 上下文（平台在事件时采集）*/
    char              window_title[256];
    char              process_name[256];
    int               pid;
    char              control_text[512];
    char              exe_path[512];
} step_event_t;

typedef void (*step_event_cb)(const step_event_t *ev, void *userdata);

/* 平台生命周期 */
os_platform_t os_get_platform(void);
int  os_init(void);
void os_shutdown(void);
/* 申请/检查权限（辅助功能等）。返回 1=已授权, 0=未授权 */
int  os_ensure_permissions(void);

/* 事件捕获: 每收到一次原始键鼠/滚轮事件就回调 cb */
int  os_start_capture(step_event_cb cb, void *userdata);
void os_stop_capture(void);

/*
 * 截取当前窗口（或全屏）并合成鼠标指针图标 + 操作标记。
 * op_marker 可为 NULL（如按键事件）。成功返回 0，*out_png 由调用方 free。
 */
int os_capture_screenshot(const step_event_t *ev,
                          const char *op_marker,
                          uint8_t **out_png, size_t *out_len);

/* 系统/硬件信息 */
typedef struct {
    char    os_name[128];
    char    os_version[128];
    char    cpu_brand[128];
    int     cpu_cores;
    uint64_t mem_bytes;
    char    hostname[128];
} system_info_t;
int os_get_system_info(system_info_t *out);

/* 在平台主线程执行 fn(arg)（macOS 用 dispatch_async 主队列；其他平台直接调用）*/
void os_run_on_main(void (*fn)(void *), void *arg);

/* 工具条 UI（平台相关）*/
typedef void (*toolbar_cb)(void);
int  os_show_toolbar(toolbar_cb on_start, toolbar_cb on_stop,
                     toolbar_cb on_save, toolbar_cb on_settings);
void os_set_recording_state(int recording);
void os_set_tick_callback(double (*cb)(void));   /* 用于刷新计时显示 */
void os_hide_toolbar(void);

/* 截图模式: 0=当前窗口, 1=全屏 */
void os_toggle_capture_mode(void);
const char *os_capture_mode_label(void);

#ifdef __cplusplus
}
#endif

#endif /* OS_API_H */
