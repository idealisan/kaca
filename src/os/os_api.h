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
    STEP_EVENT_SCROLL,
    STEP_EVENT_FOCUS,       /* 前台窗口/应用切换（由轮询检测）*/
    STEP_EVENT_TYPE         /* 连续的文字输入（由 recorder 合并多个 KEY 得到）*/
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
    char              key_text[64]; /* 本次按键产生的文字，或 [回车]/[删除] 等标记；
                                       为空表示非文字键（Esc/方向/F 键/纯修饰键等）。
                                       用于把连续输入合并为一次「文字输入」动作。*/

    /* MOUSE */
    int               button;
    /* 鼠标点击相对位置（百分比 0-100；rel_mode: 0 无 / 1 相对窗口 / 2 相对屏幕）*/
    int               rel_x_pct;
    int               rel_y_pct;
    int               rel_mode;

    /* SCROLL（单步原始增量）*/
    int               scroll_dx;   /* 水平: +右 -左 */
    int               scroll_dy;   /* 垂直: +下 -上 */

    /* 上下文（平台在事件时采集）*/
    char              window_title[256];
    char              process_name[256];
    int               pid;
    char              control_text[512];
    char              exe_path[512];
    uint32_t          window_id;   /* 事件发生时所在窗口 ID（0=无）；截图按它冻结目标，
                                      避免异步截图时用户已切走导致截到别的窗口 */
    uint32_t          mod_flags;   /* 修饰键标志（见下方 MOD_* 位定义）；用于识别快捷键组合 */
} step_event_t;

/* 修饰键标志位（值取自 Quartz kCGEventFlagMask*；公共逻辑与平台共用此定义）*/
#define MOD_COMMAND  0x100000u   /* kCGEventFlagMaskCommand */
#define MOD_CONTROL  0x040000u   /* kCGEventFlagMaskControl  */
#define MOD_OPTION   0x080000u   /* kCGEventFlagMaskAlternate*/
#define MOD_SHIFT    0x020000u   /* kCGEventFlagMaskShift   */

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
 * 帧环形缓冲（时间对齐用）。
 * 录制开始时调用 os_frame_capture_start：在后台线程以固定帧率持续抓取整屏，
 * 每帧打上 CFAbsoluteTime 时间戳存入环形缓冲。
 * 停止时调用 os_frame_capture_stop：停止抓取并释放缓冲。
 * 抓取用进程内 CGDisplayCreateImage（无 screencapture 子进程，延迟低），后台线程执行，
 * 不阻塞事件分发。
 */
void os_frame_capture_start(void);
void os_frame_capture_stop(void);

/*
 * 按事件时间取一帧并合成鼠标指针 + 操作标记，编码为 WebP 后异步回调。
 * 内部会：① 从环形缓冲选出「时间戳不晚于 ev->timestamp」、且（FOCUS 时）前台窗口
 * 已进入 ev->window_id 的那一帧；② 窗口模式下按 ev->window_id 的 bounds 裁剪；
 * ③ 在主线程合成光标/标记；④ libwebp 编码为 WebP。
 * cb(data, len, ud) 的 data 为 malloc 的 WebP 字节，由回调方 free；失败则 (NULL,0)。
 * 用于事件回调里，做到「截图时间 == 事件时间」，而非延迟很久后才拍。
 */
void os_grab_frame_for_event(const step_event_t *ev, const char *op_marker,
                             void (*cb)(uint8_t *data, size_t len, void *ud), void *ud);

/* 当前光标位置（CG 坐标系，左上原点）。用于轮询焦点切换时记录指针位置。*/
void os_get_cursor(int *x, int *y);

/*
 * 当前最前台窗口/应用信息（轮询焦点切换用）。
 * 返回 1 表示取到，0 表示失败。各 out 可为 NULL。
 */
int os_get_frontmost_window(char *app, size_t app_n,
                            char *title, size_t title_n,
                            int *pid, char *exe, size_t exe_n);

/* 在主线程泵一下 run loop（macOS 用于停止录制后等待异步截图收尾；其他平台为空操作）。*/
void os_drain_main(void);

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

/* 打开系统「辅助功能」设置页（用于引导授权）*/
void os_open_accessibility_settings(void);

/* 工具条 UI（平台相关）*/

/*
 * 弹出保存对话框，让用户选择报告保存路径与文件名。
 * 返回 malloc 的路径字符串（调用方 free），用户取消或不支持时返回 NULL。
 * default_name 为默认文件名（不含目录）。
 */
char *os_show_save_dialog(const char *default_name);

typedef void (*toolbar_cb)(void);
int  os_show_toolbar(toolbar_cb on_start, toolbar_cb on_stop);
void os_set_recording_state(int recording);
void os_set_tick_callback(double (*cb)(void));   /* 用于刷新计时显示 */
void os_hide_toolbar(void);

/* 截图模式: 0=当前窗口, 1=全屏 */
void os_set_capture_mode(int fullscreen);
int  os_get_capture_mode(void);
const char *os_capture_mode_label(void);

#ifdef __cplusplus
}
#endif

#endif /* OS_API_H */
