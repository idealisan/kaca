#include "recorder.h"
#include "base64.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/time.h>

/* ------------------------------------------------------------------ */
/* 单步记录                                                            */
/* ------------------------------------------------------------------ */
typedef struct {
    int      number;
    step_event_kind_t kind; /* 事件类型（用于报告里的差异化渲染）*/
    double   timestamp;     /* unix 秒 */
    double   rel_seconds;   /* 相对录制开始 */
    char     desc[256];
    char     typed_text[1024]; /* TYPE 步骤的原文（用户输入的文字）*/
    int      pause_after;      /* TYPE 步骤后停顿秒数（>0 时显示）*/
    /* 附加信息（默认隐藏）*/
    char     window_title[256];
    char     process_name[256];
    int      pid;
    char     control_text[512];
    char     exe_path[512];
    int      cursor_x, cursor_y;
    /* 截图 */
    uint8_t *png;
    size_t   png_len;
} step_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static step_t *g_steps = NULL;
static int      g_step_count = 0;
static int      g_step_cap = 0;

static int   g_recording = 0;
static double g_start_time = 0;

/* 进行中的滚动（1 秒窗口分组）*/
static step_event_t g_pending;
static int   g_pending_active = 0;
static double g_pending_last = 0;

/* 进行中的文字输入（连续按键合并为一次动作；停顿 >3s 视为一段结束）*/
#define TYPING_MAX 1023
static struct {
    int          active;
    double       last_time;
    char         text[TYPING_MAX + 1];
    int          count;        /* 累计按键次数 */
    step_event_t last;         /* 最近一次按键事件（保留上下文/光标，用于截图）*/
} g_typing;

static pthread_t g_timer_thread;
static int   g_timer_running = 0;

/* 在途异步截图计数（停止录制后需排空）*/
static int   g_shots_inflight = 0;

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */
static double now_unix(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void fmt_rel(double sec, char *out, size_t n) {
    long s = (long)sec;
    long h = s / 3600, m = (s % 3600) / 60, ss = s % 60;
    snprintf(out, n, "%02ld:%02ld:%02ld", h, m, ss);
}

static char *html_escape(const char *s) {
    if (!s) s = "";
    size_t need = strlen(s) * 6 + 1;
    char *o = (char *)malloc(need);
    if (!o) return strdup("");
    char *p = o;
    for (; *s; s++) {
        switch (*s) {
            case '&': memcpy(p, "&amp;", 5); p += 5; break;
            case '<': memcpy(p, "&lt;", 4);  p += 4; break;
            case '>': memcpy(p, "&gt;", 4);  p += 4; break;
            case '"': memcpy(p, "&quot;", 6);p += 6; break;
            default:  *p++ = *s; break;
        }
    }
    *p = '\0';
    return o;
}

/* 极简可增长字符串 */
typedef struct { char *buf; size_t len, cap; } sb_t;
static void sb_init(sb_t *s) {
    s->cap = 8192; s->len = 0;
    s->buf = (char *)malloc(s->cap);
    if (s->buf) s->buf[0] = '\0';
}
static void sb_append(sb_t *s, const char *fmt, ...) {
    if (!s->buf) return;
    for (;;) {
        va_list ap; va_start(ap, fmt);
        int n = vsnprintf(s->buf + s->len, s->cap - s->len, fmt, ap);
        va_end(ap);
        if (n < 0) return;
        if ((size_t)n < s->cap - s->len) { s->len += (size_t)n; return; }
        s->cap = s->len + (size_t)n + 4096;
        char *nb = (char *)realloc(s->buf, s->cap);
        if (!nb) return;
        s->buf = nb;
    }
}

/* 原样追加字面量字符串（不做 printf 格式化，避免吞掉 CSS 里的 %）*/
static void sb_append_str(sb_t *s, const char *str) {
    if (!s->buf) return;
    size_t add = strlen(str);
    while (s->len + add + 1 > s->cap) {
        s->cap *= 2;
        char *nb = (char *)realloc(s->buf, s->cap);
        if (!nb) return;
        s->buf = nb;
    }
    memcpy(s->buf + s->len, str, add + 1);
    s->len += add;
}

/* ------------------------------------------------------------------ */
/* 描述文本构造                                                        */
/* ------------------------------------------------------------------ */
static void build_key_desc(char *out, size_t n, const step_event_t *ev) {
    snprintf(out, n, "按下按键 [%s]", ev->key_name[0] ? ev->key_name : "?");
}
static void build_mouse_desc(char *out, size_t n, const step_event_t *ev) {
    const char *b = ev->button == MOUSE_BTN_LEFT  ? "左键"
                  : ev->button == MOUSE_BTN_RIGHT ? "右键"
                  : ev->button == MOUSE_BTN_MIDDLE? "中键" : "其他键";
    if (ev->rel_mode == 1)
        snprintf(out, n, "鼠标%s点击 (%d, %d) — 窗口内 左 %d%% / 上 %d%%",
                 b, ev->cursor_x, ev->cursor_y, ev->rel_x_pct, ev->rel_y_pct);
    else if (ev->rel_mode == 2)
        snprintf(out, n, "鼠标%s点击 (%d, %d) — 屏幕 左 %d%% / 上 %d%%",
                 b, ev->cursor_x, ev->cursor_y, ev->rel_x_pct, ev->rel_y_pct);
    else
        snprintf(out, n, "鼠标%s点击 (%d, %d)", b, ev->cursor_x, ev->cursor_y);
}
static void build_scroll_desc(char *out, size_t n, const step_event_t *ev) {
    int dy = ev->scroll_dy, dx = ev->scroll_dx;
    if (dy != 0 && dx != 0) {
        const char *vd = dy > 0 ? "下" : "上";
        const char *hd = dx > 0 ? "右" : "左";
        snprintf(out, n, "滚轮向%s/%s滚动 %d/%d 单位", vd, hd, abs(dy), abs(dx));
    } else if (dy != 0) {
        snprintf(out, n, "滚轮向%s滚动 %d 单位", dy > 0 ? "下" : "上", abs(dy));
    } else {
        snprintf(out, n, "滚轮向%s滚动 %d 单位", dx > 0 ? "右" : "左", abs(dx));
    }
}
static void mouse_marker(char *out, size_t n, const step_event_t *ev) {
    const char *b = ev->button == MOUSE_BTN_LEFT  ? "左键"
                  : ev->button == MOUSE_BTN_RIGHT ? "右键"
                  : ev->button == MOUSE_BTN_MIDDLE? "中键" : "点击";
    snprintf(out, n, "%s", b);
}
static void scroll_marker(char *out, size_t n, const step_event_t *ev) {
    if (ev->scroll_dy > 0)      snprintf(out, n, "滚轮↓");
    else if (ev->scroll_dy < 0) snprintf(out, n, "滚轮↑");
    else if (ev->scroll_dx > 0) snprintf(out, n, "滚轮→");
    else                        snprintf(out, n, "滚轮←");
}
static void build_focus_desc(char *out, size_t n, const step_event_t *ev) {
    if (ev->window_title[0])
        snprintf(out, n, "切换到「%s」— 窗口「%s」",
                 ev->process_name[0] ? ev->process_name : "?", ev->window_title);
    else
        snprintf(out, n, "切换到「%s」", ev->process_name[0] ? ev->process_name : "?");
}

/* ------------------------------------------------------------------ */
/* 步骤写入                                                            */
/* ------------------------------------------------------------------ */

/* 异步截图完成后回调：把 PNG 挂到指定序号的步骤上。*/
static void attach_screenshot(uint8_t *png, size_t len, void *ud) {
    int *idxp = (int *)ud;
    pthread_mutex_lock(&g_lock);
    if (*idxp >= 0 && *idxp < g_step_count) {
        step_t *s = &g_steps[*idxp];
        s->png = png;
        s->png_len = len;
    } else {
        free(png);
    }
    if (g_shots_inflight > 0) g_shots_inflight--;
    pthread_mutex_unlock(&g_lock);
    free(idxp);
}

static void add_step_ex(const step_event_t *ev, const char *desc, const char *marker,
                         const char *typed, int pause_after) {
    pthread_mutex_lock(&g_lock);
    if (g_step_count == g_step_cap) {
        g_step_cap = g_step_cap ? g_step_cap * 2 : 32;
        step_t *ns = (step_t *)realloc(g_steps, g_step_cap * sizeof(step_t));
        if (!ns) { pthread_mutex_unlock(&g_lock); return; }
        g_steps = ns;
    }
    int idx = g_step_count;
    step_t *s = &g_steps[g_step_count++];
    memset(s, 0, sizeof(*s));
    s->number     = g_step_count;
    s->kind       = ev->kind;
    s->timestamp  = ev->timestamp;
    s->rel_seconds= ev->timestamp - g_start_time;
    strncpy(s->desc, desc, sizeof(s->desc) - 1);
    if (typed) strncpy(s->typed_text, typed, sizeof(s->typed_text) - 1);
    s->pause_after = pause_after;
    strncpy(s->window_title, ev->window_title, sizeof(s->window_title) - 1);
    strncpy(s->process_name, ev->process_name, sizeof(s->process_name) - 1);
    s->pid        = ev->pid;
    strncpy(s->control_text, ev->control_text, sizeof(s->control_text) - 1);
    strncpy(s->exe_path, ev->exe_path, sizeof(s->exe_path) - 1);
    s->cursor_x   = ev->cursor_x;
    s->cursor_y   = ev->cursor_y;
    s->png        = NULL;
    s->png_len    = 0;
    g_shots_inflight++;
    pthread_mutex_unlock(&g_lock);

    /* 截图异步进行，避免阻塞事件分发（否则会卡顿并丢事件）*/
    int *idxp = (int *)malloc(sizeof(int));
    if (idxp) { *idxp = idx; os_async_screenshot(ev, marker, attach_screenshot, idxp); }
}

static void add_step(const step_event_t *ev, const char *desc, const char *marker) {
    add_step_ex(ev, desc, marker, NULL, 0);
}

static void free_steps(void) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_step_count; i++) free(g_steps[i].png);
    g_step_count = 0;
    pthread_mutex_unlock(&g_lock);
}

/* 将进行中的滚动定稿为一步（必须在主线程调用，因为会截图）*/
static void finalize_pending(void) {
    pthread_mutex_lock(&g_lock);
    int active = g_pending_active;
    double last = g_pending_last;
    pthread_mutex_unlock(&g_lock);
    if (!active) return;
    if (now_unix() - last <= 1.0) return; /* 还没停够 1 秒（防提前定稿）*/

    step_event_t ev;
    pthread_mutex_lock(&g_lock);
    ev = g_pending;
    g_pending_active = 0;
    pthread_mutex_unlock(&g_lock);

    char desc[256]; build_scroll_desc(desc, sizeof(desc), &ev);
    char marker[32]; scroll_marker(marker, sizeof(marker), &ev);
    add_step(&ev, desc, marker);
}

/* 滚动分组：1 秒窗口内连续合并，停顿 >1 秒算新一次 */
static void handle_scroll(const step_event_t *ev) {
    double now = ev->timestamp;
    pthread_mutex_lock(&g_lock);
    if (g_pending_active && (now - g_pending_last > 1.0)) {
        pthread_mutex_unlock(&g_lock);
        finalize_pending();              /* 先定稿旧的（在主线程）*/
        pthread_mutex_lock(&g_lock);
    }
    if (!g_pending_active) {
        g_pending = *ev;
        g_pending.scroll_dx = ev->scroll_dx;
        g_pending.scroll_dy = ev->scroll_dy;
        g_pending_active = 1;
    } else {
        g_pending.scroll_dx += ev->scroll_dx;
        g_pending.scroll_dy += ev->scroll_dy;
        g_pending.cursor_x = ev->cursor_x;
        g_pending.cursor_y = ev->cursor_y;
        strncpy(g_pending.window_title, ev->window_title, sizeof(g_pending.window_title) - 1);
        strncpy(g_pending.process_name, ev->process_name, sizeof(g_pending.process_name) - 1);
        g_pending.pid = ev->pid;
        strncpy(g_pending.control_text, ev->control_text, sizeof(g_pending.control_text) - 1);
        strncpy(g_pending.exe_path, ev->exe_path, sizeof(g_pending.exe_path) - 1);
    }
    g_pending_last = now;
    pthread_mutex_unlock(&g_lock);
}

/* 滚动计时线程：每 100ms 检查，停顿 >1 秒则回主线程定稿 */
static void finalize_typing(int from_pause);   /* 前向声明（timer_main 用到）*/
static void finalize_typing_on_timer(void *ud) { (void)ud; finalize_typing(1); }
static void *timer_main(void *arg) {
    (void)arg;
    while (g_timer_running) {
        usleep(100000);
        double now = now_unix();
        pthread_mutex_lock(&g_lock);
        int s_active = g_pending_active;
        double s_last = g_pending_last;
        int t_active = g_typing.active;
        double t_last = g_typing.last_time;
        pthread_mutex_unlock(&g_lock);
        if (s_active && (now - s_last > 1.0)) {
            os_run_on_main((void (*)(void *))finalize_pending, NULL);
        }
        /* 文字输入停顿 >3 秒：定稿为一段（回到主线程截图）*/
        if (t_active && (now - t_last > 3.0)) {
            os_run_on_main(finalize_typing_on_timer, NULL);
        }
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* 文字输入合并（连续按键 -> 一次「文字输入」动作）                      */
/* ------------------------------------------------------------------ */
/* key_text 非空即为可合并的文字输入键（含 [回车]/[删除] 等标记）*/
static int key_is_typing(const step_event_t *ev) {
    return ev->key_text[0] != '\0';
}

static void typing_append(const step_event_t *ev) {
    pthread_mutex_lock(&g_lock);
    if (!g_typing.active) {
        g_typing.active = 1;
        g_typing.last_time = ev->timestamp;
        g_typing.text[0] = '\0';
        g_typing.count = 0;
    }
    size_t cur = strlen(g_typing.text);
    size_t add = strlen(ev->key_text);
    if (cur + add <= TYPING_MAX) {
        memcpy(g_typing.text + cur, ev->key_text, add + 1);
    }
    g_typing.count++;
    g_typing.last_time = ev->timestamp;
    g_typing.last = *ev;     /* 保留最近一次按键的上下文/光标，用于截图 */
    pthread_mutex_unlock(&g_lock);
}

/* 把当前文字输入定稿为一步。
 * from_pause: 1=因停顿定时触发（停顿 >3s，总是记录停顿秒数）；
 *             0=被其他动作打断（仅当实际停顿 >3s 才记录）。*/
static void finalize_typing(int from_pause) {
    double now = now_unix();
    pthread_mutex_lock(&g_lock);
    if (!g_typing.active) { pthread_mutex_unlock(&g_lock); return; }
    int gap = (int)(now - g_typing.last_time + 0.5);
    int pause_after = (from_pause || gap > 3) ? gap : 0;
    char text[TYPING_MAX + 1];
    memcpy(text, g_typing.text, sizeof(text));
    int count = g_typing.count;
    step_event_t last = g_typing.last;
    g_typing.active = 0;
    pthread_mutex_unlock(&g_lock);

    last.kind = STEP_EVENT_TYPE;
    char desc[256];
    snprintf(desc, sizeof(desc), "用户输入了文字（%d 次按键）", count);
    add_step_ex(&last, desc, NULL, text, pause_after);
}

/* ------------------------------------------------------------------ */
/* 事件入口                                                            */
/* ------------------------------------------------------------------ */
void recorder_handle_event(const step_event_t *ev, void *userdata) {
    (void)userdata;
    if (!g_recording) return;
    switch (ev->kind) {
        case STEP_EVENT_KEY: {
            if (key_is_typing(ev)) {
                typing_append(ev);
            } else {
                finalize_typing(0);              /* 非文字键：先结束输入段 */
                char d[256]; build_key_desc(d, sizeof(d), ev);
                add_step(ev, d, NULL);
            }
            break;
        }
        case STEP_EVENT_MOUSE: {
            finalize_typing(0);
            char d[256]; build_mouse_desc(d, sizeof(d), ev);
            char m[32]; mouse_marker(m, sizeof(m), ev);
            add_step(ev, d, m);
            break;
        }
        case STEP_EVENT_SCROLL:
            finalize_typing(0);
            handle_scroll(ev);
            break;
        case STEP_EVENT_FOCUS: {
            finalize_typing(0);
            char d[256]; build_focus_desc(d, sizeof(d), ev);
            add_step(ev, d, NULL);
            break;
        }
        default: break;
    }
}

double recorder_elapsed(void) {
    if (!g_recording) return 0.0;
    return now_unix() - g_start_time;
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */
void recorder_init(void) {
    g_steps = NULL; g_step_count = 0; g_step_cap = 0;
    g_recording = 0; g_pending_active = 0; g_timer_running = 0;
    g_shots_inflight = 0;
    g_typing.active = 0; g_typing.text[0] = '\0'; g_typing.count = 0;
}

void recorder_start(void) {
    free_steps();                       /* 内部自行加锁 */
    pthread_mutex_lock(&g_lock);
    g_recording = 1;
    g_start_time = now_unix();
    g_pending_active = 0;
    g_typing.active = 0;
    pthread_mutex_unlock(&g_lock);

    g_timer_running = 1;
    pthread_create(&g_timer_thread, NULL, timer_main, NULL);
}

void recorder_stop(void) {
    finalize_pending();                 /* 定稿残留滚动（主线程）*/
    finalize_typing(0);                  /* 定稿残留文字输入（主线程）*/
    g_recording = 0;
    g_timer_running = 0;
    pthread_join(g_timer_thread, NULL);
    /* 等所有在途异步截图收尾（macOS 会泵主 run loop，避免保存时漏截图）*/
    for (int i = 0; i < 200; i++) {
        int inflight;
        pthread_mutex_lock(&g_lock); inflight = g_shots_inflight; pthread_mutex_unlock(&g_lock);
        if (inflight <= 0) break;
        os_drain_main();
    }
}

void recorder_free(void) {
    free_steps();
    free(g_steps);
    g_steps = NULL;
}

/* ------------------------------------------------------------------ */
/* HTML 报告生成                                                       */
/* ------------------------------------------------------------------ */
static char *build_html(void) {
    system_info_t si; os_get_system_info(&si);

    sb_t sb; sb_init(&sb);
    sb_append_str(&sb,
        "<!doctype html>\n<html lang=\"zh\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        "<title>步骤记录报告</title>\n<style>\n"
        "body{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;"
        "margin:0;background:#f5f6f8;color:#222}\n"
        ".card{margin:16px;padding:16px 20px;border-radius:12px;background:#fff;"
        "box-shadow:0 1px 3px rgba(0,0,0,.1)}\n"
        ".card h2{margin:0 0 12px;font-size:18px}\n"
        ".sysgrid{display:grid;grid-template-columns:auto 1fr;gap:6px 16px;font-size:14px}\n"
        ".sysgrid div:nth-child(odd){color:#888}\n"
        ".step{margin:16px;border-radius:12px;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1);"
        "position:relative}\n"
        ".step-head{display:flex;align-items:center;gap:12px;padding:12px 16px;"
        "border-bottom:1px solid #eee;position:relative}\n"
        ".step-no{font-weight:700;color:#2b6cff;font-size:16px}\n"
        ".step-time{color:#666;font-variant-numeric:tabular-nums}\n"
        ".step-rel{color:#2b6cff;font-variant-numeric:tabular-nums}\n"
        ".step-desc{font-weight:600}\n"
        ".info{margin-left:auto;border:1px solid #ccc;background:#fff;border-radius:50%;"
        "width:22px;height:22px;cursor:pointer;font-style:italic;font-weight:700;color:#2b6cff;"
        "line-height:20px;text-align:center}\n"
        ".pop{display:none;position:absolute;right:16px;top:42px;z-index:10;background:#222;"
        "color:#eee;padding:10px 12px;border-radius:8px;font-size:12px;white-space:pre-line;"
        "box-shadow:0 4px 12px rgba(0,0,0,.3);max-width:340px;line-height:1.6}\n"
        ".pop.show{display:block}\n"
        ".shot{display:block;width:100%;border-bottom-left-radius:12px;"
        "border-bottom-right-radius:12px}\n"
        ".typed{margin:0;padding:12px 16px;background:#f7f9ff;border-bottom:1px solid #eee;"
        "white-space:pre-wrap;word-break:break-word;font-size:14px;line-height:1.6;color:#1a1a2e}\n"
        ".pause{display:inline-block;margin:0 16px 12px;padding:4px 10px;background:#fff4e6;"
        "border:1px solid #ffd8a8;border-radius:999px;color:#b35309;font-size:12px}\n"
        ".empty{padding:40px;text-align:center;color:#999}\n"
        "</style>\n</head>\n<body>\n");

    /* 系统信息卡片 */
    sb_append(&sb, "<div class=\"card\"><h2>系统信息</h2><div class=\"sysgrid\">");
    sb_append(&sb, "<div>操作系统</div><div>%s %s</div>",
              html_escape(si.os_name), html_escape(si.os_version));
    sb_append(&sb, "<div>CPU</div><div>%s</div>", html_escape(si.cpu_brand));
    sb_append(&sb, "<div>CPU 核心数</div><div>%d</div>", si.cpu_cores);
    double gb = (double)si.mem_bytes / (1024.0 * 1024.0 * 1024.0);
    sb_append(&sb, "<div>内存</div><div>%.1f GB</div>", gb);
    sb_append(&sb, "<div>主机名</div><div>%s</div>", html_escape(si.hostname));

    time_t gt = time(NULL);
    struct tm gtm; localtime_r(&gt, &gtm);
    char gbuf[64]; strftime(gbuf, sizeof(gbuf), "%Y-%m-%d %H:%M:%S", &gtm);
    sb_append(&sb, "<div>生成时间</div><div>%s</div>", html_escape(gbuf));
    sb_append(&sb, "</div></div>\n");

    /* 步骤 */
    pthread_mutex_lock(&g_lock);
    int count = g_step_count;
    sb_append(&sb, "<div class=\"card\"><h2>操作步骤（共 %d 步）</h2>", count);
    if (count == 0) {
        sb_append(&sb, "<div class=\"empty\">暂无记录</div>");
    }
    for (int i = 0; i < count; i++) {
        step_t *s = &g_steps[i];
        char tbuf[64], rel[32];
        time_t t = (time_t)s->timestamp;
        struct tm tm; localtime_r(&t, &tm);
        strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", &tm);
        fmt_rel(s->rel_seconds, rel, sizeof(rel));

        char *wt = html_escape(s->window_title);
        char *pn = html_escape(s->process_name);
        char *ct = html_escape(s->control_text);
        char *ep = html_escape(s->exe_path);

        sb_append(&sb,
            "<div class=\"step\">"
            "<div class=\"step-head\">"
            "<span class=\"step-no\">%d</span>"
            "<span class=\"step-time\">%s</span>"
            "<span class=\"step-rel\">相对 %s</span>"
            "<span class=\"step-desc\">%s</span>"
            "<button class=\"info\" onclick=\"togglePop(this)\">i</button>"
            "<div class=\"pop\">进程: %s (pid %d)\n窗口标题: %s\n控件文本: %s\n"
            "可执行文件: %s\n光标位置: (%d, %d)</div>"
            "</div>",
            s->number, tbuf, rel, html_escape(s->desc),
            pn, s->pid, wt, ct, ep, s->cursor_x, s->cursor_y);

        if (s->kind == STEP_EVENT_TYPE) {
            char *tt = html_escape(s->typed_text);
            sb_append(&sb, "<div class=\"typed\">%s</div>", tt);
            free(tt);
            if (s->pause_after > 0)
                sb_append(&sb, "<div class=\"pause\">停顿 %d 秒后继续</div>", s->pause_after);
        }

        if (s->png && s->png_len) {
            char *b64 = NULL;
            base64_encode(s->png, s->png_len, &b64);
            if (b64) {
                sb_append(&sb, "<img class=\"shot\" src=\"data:image/png;base64,%s\">", b64);
                free(b64);
            }
        }
        sb_append(&sb, "</div>\n");

        free(wt); free(pn); free(ct); free(ep);
    }
    sb_append(&sb, "</div>\n");
    pthread_mutex_unlock(&g_lock);

    sb_append_str(&sb,
        "<script>\n"
        "function togglePop(btn){"
        "  var pop=btn.parentElement.querySelector('.pop');"
        "  var was=pop.classList.contains('show');"
        "  document.querySelectorAll('.pop').forEach(function(p){p.classList.remove('show');});"
        "  if(!was) pop.classList.add('show');"
        "}\n"
        "document.addEventListener('click',function(e){"
        "  if(!e.target.classList.contains('info'))"
        "    document.querySelectorAll('.pop').forEach(function(p){p.classList.remove('show');});"
        "});\n"
        "</script>\n</body>\n</html>\n");

    return sb.buf;
}

const char *recorder_save_to(const char *path) {
    if (!path || !path[0]) return NULL;
    char *html = build_html();
    if (!html) return NULL;

    FILE *f = fopen(path, "wb");
    if (!f) { free(html); return NULL; }
    fwrite(html, 1, strlen(html), f);
    fclose(f);
    free(html);

    static char ret[1024];
    strncpy(ret, path, sizeof(ret) - 1);
    ret[sizeof(ret) - 1] = '\0';
    return ret;
}

const char *recorder_save_default(void) {
    /* 输出到当前工作目录（即项目目录）*/
    char path[1024];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    char ts[32]; strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", &tm);
    snprintf(path, sizeof(path), "step-report-%s.html", ts);
    return recorder_save_to(path);
}
