/* 无界面自测：用桩替换依赖显示的 OS 调用，验证滚动分组 / 相对时间 / HTML 生成 */
#include "recorder.h"
#include "os/os_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>

static void on_alarm(int s) { (void)s; fprintf(stderr, "WATCHDOG TIMEOUT — hang detected\n"); _exit(2); }

static double now_unix(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

/* 1x1 透明 PNG */
static const uint8_t PNG1x1[] = {
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,
    0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,
    0x15,0xC4,0x89,0x00,0x00,0x00,0x0A,0x49,0x44,0x41,0x54,0x78,0x9C,0x63,0x00,
    0x01,0x00,0x00,0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00,0x00,0x00,0x00,0x49,
    0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
};

int os_capture_screenshot(const step_event_t *ev, const char *m,
                          uint8_t **out_png, size_t *out_len) {
    (void)ev; (void)m;
    *out_png = malloc(sizeof(PNG1x1));
    memcpy(*out_png, PNG1x1, sizeof(PNG1x1));
    *out_len = sizeof(PNG1x1);
    return 0;
}
int os_get_system_info(system_info_t *out) {
    memset(out, 0, sizeof(*out));
    strcpy(out->os_name, "TestOS");
    strcpy(out->os_version, "1.0");
    strcpy(out->cpu_brand, "Test CPU");
    out->cpu_cores = 8;
    out->mem_bytes = 16ULL * 1024 * 1024 * 1024;
    strcpy(out->hostname, "testbox");
    return 0;
}
void os_run_on_main(void (*fn)(void *), void *arg) { fn(arg); }

void os_async_screenshot(const step_event_t *ev, const char *m,
                         void (*cb)(uint8_t *, size_t, void *), void *ud) {
    uint8_t *p = NULL; size_t l = 0;
    os_capture_screenshot(ev, m, &p, &l);   /* 测试里同步完成 */
    cb(p, l, ud);
}
void os_get_cursor(int *x, int *y) { *x = 0; *y = 0; }
int os_get_frontmost_window(char *app, size_t app_n, char *title, size_t title_n,
                            int *pid, char *exe, size_t exe_n) {
    if (app && app_n) app[0] = '\0';
    if (title && title_n) title[0] = '\0';
    if (pid) *pid = 0;
    if (exe && exe_n) exe[0] = '\0';
    return 0;
}
void os_drain_main(void) {}
char *os_show_save_dialog(const char *default_name) { (void)default_name; return NULL; }

static void ev_init(step_event_t *e) { memset(e, 0, sizeof(*e)); e->timestamp = now_unix(); }

#define STAGE(msg) do { printf("[stage] %s\n", msg); fflush(stdout); } while (0)

int main(void) {
    signal(SIGALRM, on_alarm);
    alarm(12);

    recorder_init();
    recorder_start();
    STAGE("started");

    step_event_t e;

    /* 1) 连续输入 "Hello" -> 应合并为 1 个文字输入步骤 */
    for (const char *p = "Hello"; *p; p++) {
        ev_init(&e); e.kind = STEP_EVENT_KEY; e.keycode = 0x00; strcpy(e.key_name, "X");
        e.key_text[0] = *p; e.key_text[1] = '\0';
        e.cursor_x = 100; e.cursor_y = 100;
        strcpy(e.window_title, "文档"); strcpy(e.process_name, "TestApp"); e.pid = 42;
        strcpy(e.control_text, "保存"); strcpy(e.exe_path, "/Apps/TestApp");
        recorder_handle_event(&e, NULL);
    }
    STAGE("typing burst fed");

    /* 停顿 >3s，定时器应把 "Hello" 定稿为一段 */
    usleep(3300000);
    STAGE("after 3.3s (typing should be finalized)");

    /* 2) 非文字键（Esc，key_text 为空）-> 普通按键步骤，同时结束输入段 */
    ev_init(&e); e.kind = STEP_EVENT_KEY; e.keycode = 0x35; strcpy(e.key_name, "Escape");
    e.key_text[0] = '\0';
    recorder_handle_event(&e, NULL);
    STAGE("escape recorded");

    /* 3) 鼠标左键（带相对位置）*/
    ev_init(&e); e.kind = STEP_EVENT_MOUSE; e.button = MOUSE_BTN_LEFT;
    e.cursor_x = 200; e.cursor_y = 150;
    e.rel_mode = 1; e.rel_x_pct = 30; e.rel_y_pct = 20;
    recorder_handle_event(&e, NULL);
    STAGE("mouse recorded");

    /* 3) 连续滚动（同 1 秒内，应合并为一次，dy=300）*/
    double t0 = now_unix();
    for (int i = 0; i < 3; i++) {
        ev_init(&e); e.kind = STEP_EVENT_SCROLL; e.scroll_dy = 100;
        e.cursor_x = 300; e.cursor_y = 400; e.timestamp = t0;
        recorder_handle_event(&e, NULL);
    }
    STAGE("scroll batch fed");

    usleep(1200000);
    STAGE("after 1.2s (scroll should be finalized)");

    /* 4) 停顿后再次滚动，应算新的一次 */
    ev_init(&e); e.kind = STEP_EVENT_SCROLL; e.scroll_dy = -100;
    e.cursor_x = 300; e.cursor_y = 400;
    recorder_handle_event(&e, NULL);
    usleep(1200000);
    STAGE("second scroll finalized");

    /* 5) 仅按回车（空白输入）：不应生成「用户输入了文字」步骤 */
    ev_init(&e); e.kind = STEP_EVENT_KEY; e.keycode = 0x24; strcpy(e.key_name, "Return");
    e.key_text[0] = '\n'; e.key_text[1] = '\0';
    recorder_handle_event(&e, NULL);
    STAGE("blank return fed");

    /* 6) 快捷键 ⌘V：mod_flags 含 Command，不并入打字，应记「按下 ⌘V」*/
    ev_init(&e); e.kind = STEP_EVENT_KEY; e.keycode = 0x09; strcpy(e.key_name, "V");
    e.key_text[0] = '\0'; e.mod_flags = MOD_COMMAND;
    recorder_handle_event(&e, NULL);
    STAGE("shortcut fed");

    /* 7) 触控板横向滑动（切换桌面）：记为手势切换而非普通滚动 */
    ev_init(&e); e.kind = STEP_EVENT_SCROLL; e.scroll_dx = 3; e.scroll_dy = 0;
    e.cursor_x = 300; e.cursor_y = 400;
    recorder_handle_event(&e, NULL);
    usleep(1200000);
    STAGE("horizontal swipe fed");

    recorder_stop();
    STAGE("stopped");

    const char *path = recorder_save_default();
    printf("saved: %s\n", path ? path : "NULL");

    /* 自检：验证新行为不被回归 */
    int fail = 0;
    if (path) {
        FILE *f = fopen(path, "rb");
        if (f) {
            fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
            char *buf = (char *)malloc((size_t)sz + 1);
            if (buf) {
                fread(buf, 1, (size_t)sz, f); buf[sz] = '\0'; fclose(f);
                int n_type = 0; const char *p = buf;
                while ((p = strstr(p, "用户输入了文字"))) { n_type++; p++; }
                if (n_type != 1) {
                    fprintf(stderr, "SELFCHECK FAIL: 「用户输入了文字」出现 %d 次（期望 1）\n", n_type);
                    fail = 1;
                }
                if (!strstr(buf, "按下 ⌘V")) {
                    fprintf(stderr, "SELFCHECK FAIL: 未找到「按下 ⌘V」\n");
                    fail = 1;
                }
                if (!strstr(buf, "切换了桌面")) {
                    fprintf(stderr, "SELFCHECK FAIL: 未找到「切换了桌面」（横向滑动应记为桌面切换）\n");
                    fail = 1;
                }
                free(buf);
            } else fclose(f);
        }
    }
    if (fail) { recorder_free(); return 1; }

    recorder_free();
    STAGE("done");
    return 0;
}
