/*
 * Linux 平台桩实现（最低优先级，桌面环境不统一，TODO）。
 * 仅提供与 os_api.h 一致的接口骨架，后续补全（依桌面环境选择）：
 *   - 事件: X11 XRecord 扩展 / Wayland 各合成器私有协议
 *   - 截图: X11 XGetImage / grim(wayland) / scrot
 *   - 窗口/控件: EWMH/_NET_ACTIVE_WINDOW / AT-SPI
 *   - 系统信息: /proc/cpuinfo, /proc/meminfo, uname
 *   - 工具条: GTK/Qt
 */
#include "os/os_api.h"
#include <string.h>

os_platform_t os_get_platform(void) { return OS_PLATFORM_LINUX; }
int  os_init(void) { return 0; }
void os_shutdown(void) {}
int  os_ensure_permissions(void) { return 1; }
int  os_start_capture(step_event_cb cb, void *userdata) { (void)cb;(void)userdata; return -1; }
void os_stop_capture(void) {}
int  os_capture_screenshot(const step_event_t *ev, const char *m, uint8_t **p, size_t *l) {
    (void)ev;(void)m; *p = NULL; *l = 0; return -1;
}
int  os_get_system_info(system_info_t *out) {
    memset(out, 0, sizeof(*out));
    strcpy(out->os_name, "Linux");
    return 0;
}
void os_run_on_main(void (*fn)(void *), void *arg) { fn(arg); }
void os_async_screenshot(const step_event_t *ev, const char *m,
                         void (*cb)(uint8_t *, size_t, void *), void *ud) {
    (void)ev; uint8_t *p = NULL; size_t l = 0;
    if (os_capture_screenshot(ev, m, &p, &l) == 0) cb(p, l, ud); else cb(NULL, 0, ud);
}
void os_get_cursor(int *x, int *y) { *x = 0; *y = 0; }
int  os_get_frontmost_window(char *a, size_t an, char *t, size_t tn,
                             int *pid, char *e, size_t en) {
    (void)a;(void)an;(void)t;(void)tn;(void)pid;(void)e;(void)en; return 0;
}
void os_drain_main(void) {}
char *os_show_save_dialog(const char *dn) { (void)dn; return NULL; }
int  os_show_toolbar(toolbar_cb a, toolbar_cb b, toolbar_cb c, toolbar_cb d) {
    (void)a;(void)b;(void)c;(void)d; return -1;
}
void os_set_recording_state(int r) { (void)r; }
void os_set_tick_callback(double (*cb)(void)) { (void)cb; }
void os_hide_toolbar(void) {}
void os_toggle_capture_mode(void) {}
const char *os_capture_mode_label(void) { return "窗口"; }
void os_open_accessibility_settings(void) {}
