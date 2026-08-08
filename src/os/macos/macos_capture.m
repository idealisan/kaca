/*
 * macOS 平台实现：事件捕获、截图合成、系统信息。
 * 纯 C 能覆盖的部分（CGEventTap / CGWindowList / AX / sysctl）直接用 C，
 * 需要 AppKit 的部分（NSCursor、NSImage 绘制）只能在本 .m 里写。
 */
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <dispatch/dispatch.h>
#import <webp/encode.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <libproc.h>
#include <stdlib.h>

#include "os/os_api.h"

#define UNIX_OFFSET 978307200.0  /* CFAbsoluteTime(2001) -> unix 1970 */

/* ------------------------- 权限 / 生命周期 ------------------------- */
os_platform_t os_get_platform(void) { return OS_PLATFORM_MACOS; }

int os_init(void) { return 0; }
void os_shutdown(void) {}

int os_ensure_permissions(void) {
    CFDictionaryRef opts =
        (__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    BOOL trusted = AXIsProcessTrustedWithOptions(opts);
    return trusted ? 1 : 0;
}

/* ------------------------- 事件捕获 ------------------------- */
static step_event_cb g_cb = NULL;
static void *g_ud = NULL;
static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_src = NULL;

/* 焦点轮询（检测应用/窗口切换）*/
static NSTimer *g_focus_timer = nil;
static char     g_last_app[256];   /* 已确认的当前状态 */
static int      g_last_pid = -1;
static char     g_last_title[256];
static char     g_cand_app[256];   /* 候选：需连续两次轮询一致才确认，抑制抖动 */
static int      g_cand_pid = -2;
static char     g_cand_title[256];
static int      g_focus_baseline = 1;   /* 第一次轮询只打基线，不记录 */

static void poll_frontmost(void);

static int g_fullscreen = 0;  /* 0=当前窗口 1=全屏 */

void os_set_capture_mode(int fullscreen) { g_fullscreen = fullscreen ? 1 : 0; }
int  os_get_capture_mode(void) { return g_fullscreen; }
const char *os_capture_mode_label(void) { return g_fullscreen ? "全屏" : "窗口"; }

static void keycode_to_name(int kc, char *out, size_t n) {
    const char *name = NULL;
    switch (kc) {
        case 0x00: name = "A"; break;   case 0x01: name = "S"; break;
        case 0x02: name = "D"; break;   case 0x03: name = "F"; break;
        case 0x04: name = "H"; break;   case 0x05: name = "G"; break;
        case 0x06: name = "Z"; break;   case 0x07: name = "X"; break;
        case 0x08: name = "C"; break;   case 0x09: name = "V"; break;
        case 0x0B: name = "B"; break;   case 0x0C: name = "Q"; break;
        case 0x0D: name = "W"; break;   case 0x0E: name = "E"; break;
        case 0x0F: name = "R"; break;   case 0x10: name = "Y"; break;
        case 0x11: name = "T"; break;
        case 0x12: name = "1"; break;   case 0x13: name = "2"; break;
        case 0x14: name = "3"; break;   case 0x15: name = "4"; break;
        case 0x16: name = "6"; break;   case 0x17: name = "5"; break;
        case 0x18: name = "="; break;   case 0x19: name = "9"; break;
        case 0x1A: name = "7"; break;   case 0x1B: name = "-"; break;
        case 0x1C: name = "8"; break;   case 0x1D: name = "0"; break;
        case 0x1E: name = "]"; break;   case 0x1F: name = "O"; break;
        case 0x20: name = "U"; break;   case 0x21: name = "["; break;
        case 0x22: name = "I"; break;   case 0x23: name = "P"; break;
        case 0x25: name = "L"; break;   case 0x26: name = "J"; break;
        case 0x27: name = "'"; break;   case 0x28: name = "K"; break;
        case 0x29: name = ";"; break;   case 0x2A: name = "\\"; break;
        case 0x2B: name = ","; break;   case 0x2C: name = "/"; break;
        case 0x2D: name = "N"; break;   case 0x2E: name = "M"; break;
        case 0x2F: name = "."; break;   case 0x32: name = "`"; break;
        case 0x24: name = "Return"; break; case 0x30: name = "Tab"; break;
        case 0x31: name = "Space"; break;  case 0x33: name = "Delete"; break;
        case 0x35: name = "Escape"; break; case 0x37: name = "Command"; break;
        case 0x38: name = "Shift"; break;   case 0x39: name = "CapsLock"; break;
        case 0x3A: name = "Option"; break;  case 0x3B: name = "Control"; break;
        case 0x3C: name = "RightShift"; break; case 0x3D: name = "RightOption"; break;
        case 0x3E: name = "RightControl"; break; case 0x3F: name = "Fn"; break;
        case 0x7B: name = "Left"; break;  case 0x7C: name = "Right"; break;
        case 0x7D: name = "Down"; break;  case 0x7E: name = "Up"; break;
        case 0x73: name = "Home"; break;  case 0x77: name = "End"; break;
        case 0x74: name = "PageUp"; break;case 0x79: name = "PageDown"; break;
        case 0x72: name = "Help"; break;  case 0x75: name = "ForwardDelete"; break;
        default: break;
    }
    if (name) snprintf(out, n, "%s", name);
    else snprintf(out, n, "0x%02X", kc);
}

/* 是否为“文字输入”字符（可打印，非控制字符）*/
static int is_text_printable(const char *s) {
    if (!s || !*s) return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < 0x20) return 0;   /* 控制字符（空格 0x20 及以上视为可打印）*/
    return 1;
}

static int clamp_pct(int v) {
    if (v < 0) return 0;
    if (v > 100) return 100;
    return v;
}

/* 是否为修饰键（Command/Shift/Control/Option 等本身，区别于「按住它们组合的键」）*/
static int is_modifier_key(const char *name) {
    if (!name || !*name) return 0;
    return strcmp(name, "Command") == 0 || strcmp(name, "Shift") == 0 ||
           strcmp(name, "Control") == 0 || strcmp(name, "Option") == 0 ||
           strcmp(name, "RightShift") == 0 || strcmp(name, "RightControl") == 0 ||
           strcmp(name, "RightOption") == 0 || strcmp(name, "CapsLock") == 0 ||
           strcmp(name, "Fn") == 0;
}

/*
 * 为一次按键计算 key_text：
 * - 可打印字符 -> 该字符本身（用于合并输入）
 * - 回车/删除/Tab/Space -> 易读标记
 * - 主键盘区按键（含输入法组合期间 unicode 为空的情况）-> 用键名兜底
 * - 其余（Esc/方向/F 键/修饰键等）-> 空串（视为非文字键）
 */
/* 前向声明：CFString -> UTF-8（定义见后文） */
static void cf_to_utf8(CFStringRef s, char *out, size_t n);

static void fill_key_text(step_event_t *ev, CGEventRef event) {
    ev->key_text[0] = '\0';
    /* 快捷键组合：按住 Command/Control/Option 且当前键不是修饰键本身时，
       视为快捷键（如 ⌘V），不并入「文字输入」*/
    if ((ev->mod_flags & (MOD_COMMAND | MOD_CONTROL | MOD_OPTION)) &&
        !is_modifier_key(ev->key_name))
        return;

    UniChar buf[16]; UniCharCount n = 0;
    CGEventKeyboardGetUnicodeString(event, 16, &n, buf);
    char utf8[64]; utf8[0] = '\0';
    if (n > 0) {
        CFStringRef s = CFStringCreateWithCharacters(kCFAllocatorDefault, buf, n);
        if (s) {
            cf_to_utf8(s, utf8, sizeof(utf8));
            CFRelease(s);
        }
    }
    if (strcmp(ev->key_name, "Space") == 0)      { snprintf(ev->key_text, sizeof(ev->key_text), " "); return; }
    if (strcmp(ev->key_name, "Return") == 0)     { snprintf(ev->key_text, sizeof(ev->key_text), "\n"); return; }
    if (strcmp(ev->key_name, "Delete") == 0 ||
        strcmp(ev->key_name, "ForwardDelete") == 0){ snprintf(ev->key_text, sizeof(ev->key_text), "[删除]"); return; }
    if (strcmp(ev->key_name, "Tab") == 0)        { snprintf(ev->key_text, sizeof(ev->key_text), "[Tab]"); return; }
    if (utf8[0] && is_text_printable(utf8))       { strncpy(ev->key_text, utf8, sizeof(ev->key_text) - 1); return; }
    /* 兜底：主键盘区按键也视为输入（捕捉输入法拼音字母等）*/
    if (ev->keycode >= 0 && ev->keycode <= 0x32 && ev->key_name[0])
        { strncpy(ev->key_text, ev->key_name, sizeof(ev->key_text) - 1); return; }
    ev->key_text[0] = '\0';
}

/* 把 CFString 转成 UTF-8 写入 out（总是成功转换，NULL/失败则留空）。
   不要用 CFStringGetCStringPtr：它经常返回 NULL，且可能返回非 UTF-8 指针导致乱码。*/
static void cf_to_utf8(CFStringRef s, char *out, size_t n) {
    if (!s || n == 0) { if (out && n) out[0] = '\0'; return; }
    if (!CFStringGetCString(s, out, n, kCFStringEncodingUTF8)) out[0] = '\0';
    out[n - 1] = '\0';
}

/* 取最前台应用的窗口 ID 与 bounds（用于截图，避免按光标位置误截到 Dock 等）*/
static uint32_t frontmost_window(CGRect *outBounds) {
    @autoreleasepool {
        NSRunningApplication *ra = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (!ra) return 0;
        pid_t pid = [ra processIdentifier];
        CFArrayRef list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (!list) return 0;
        uint32_t best = 0; int best_layer = (1 << 20);
        CGRect bb = CGRectZero;
        CFIndex n = CFArrayGetCount(list);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            CFNumberRef pn = CFDictionaryGetValue(d, kCGWindowOwnerPID);
            int wp = 0; if (pn) CFNumberGetValue(pn, kCFNumberSInt32Type, &wp);
            if (wp != pid) continue;
            CFNumberRef ln = CFDictionaryGetValue(d, kCGWindowLayer);
            int layer = 0; if (ln) CFNumberGetValue(ln, kCFNumberSInt32Type, &layer);
            CFNumberRef wn = CFDictionaryGetValue(d, kCGWindowNumber);
            uint32_t wid = 0; if (wn) CFNumberGetValue(wn, kCFNumberSInt32Type, &wid);
            if (wid && layer <= best_layer) {
                best = wid; best_layer = layer;
                CFDictionaryRef bd = CFDictionaryGetValue(d, kCGWindowBounds);
                if (bd) CGRectMakeWithDictionaryRepresentation(bd, &bb);
            }
        }
        CFRelease(list);
        if (outBounds) *outBounds = bb;
        return best;
    }
}

/* 按 windowNumber 查窗口 bounds（供截图时定位光标用）*/
static int window_bounds(uint32_t wid, CGRect *outBounds) {
    if (!wid) return 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;
    int found = 0;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef num = CFDictionaryGetValue(d, kCGWindowNumber);
        uint32_t w = 0;
        if (num) CFNumberGetValue(num, kCFNumberSInt32Type, &w);
        if (w == wid) {
            CFDictionaryRef bd = CFDictionaryGetValue(d, kCGWindowBounds);
            if (bd && CGRectMakeWithDictionaryRepresentation(bd, outBounds)) found = 1;
            break;
        }
    }
    CFRelease(list);
    return found;
}

/* 找到光标所在的最前台窗口（最小 layer；同级优先非 Dock），返回其 rect 与 windowID。
   注意：Dock 有一个覆盖全屏的透明窗口，若简单取「第一个包含该点的窗口」会误选 Dock，
   因此要取 layer 最小者（最靠前），且同级时优先非 Dock 的窗口。*/
static int window_at_point(CGPoint loc, CGRect *outBounds, uint32_t *outWin) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;
    int found = 0;
    int best_layer = (1 << 20);
    int best_is_dock = 1;
    CGRect best_b = CGRectZero;
    uint32_t best_wid = 0;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFDictionaryRef bdict = CFDictionaryGetValue(d, kCGWindowBounds);
        if (!bdict) continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation(bdict, &b)) continue;
        if (!CGRectContainsPoint(b, loc)) continue;

        CFNumberRef ln = CFDictionaryGetValue(d, kCGWindowLayer);
        int layer = 0; if (ln) CFNumberGetValue(ln, kCFNumberSInt32Type, &layer);
        CFStringRef owner = CFDictionaryGetValue(d, kCGWindowOwnerName);
        int is_dock = 0;
        if (owner) {
            char o[64]; cf_to_utf8(owner, o, sizeof(o));
            is_dock = (strcmp(o, "Dock") == 0);
        }

        /* 选 layer 最小者；layer 相同时优先非 Dock */
        if (!found || layer < best_layer ||
            (layer == best_layer && best_is_dock && !is_dock)) {
            best_layer = layer; best_is_dock = is_dock;
            best_b = b; best_wid = 0;
            CFNumberRef num = CFDictionaryGetValue(d, kCGWindowNumber);
            if (num) CFNumberGetValue(num, kCFNumberSInt32Type, &best_wid);
            found = 1;
        }
    }
    CFRelease(list);
    if (found) { *outBounds = best_b; *outWin = best_wid; }
    return found;
}

/* 采集事件时的窗口/进程/控件上下文 */
static void fill_context(step_event_t *ev, CGPoint loc) {
    CGRect b; uint32_t wid = 0;
    if (window_at_point(loc, &b, &wid)) {
        CFArrayRef list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (list) {
            CFIndex n = CFArrayGetCount(list);
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
                CFNumberRef num = CFDictionaryGetValue(d, kCGWindowNumber);
                uint32_t w = 0;
                if (num) CFNumberGetValue(num, kCFNumberSInt32Type, &w);
                if (w != wid) continue;
                CFStringRef name = CFDictionaryGetValue(d, kCGWindowName);
                CFStringRef owner = CFDictionaryGetValue(d, kCGWindowOwnerName);
                CFNumberRef pidn = CFDictionaryGetValue(d, kCGWindowOwnerPID);
                int pid = 0;
                if (pidn) CFNumberGetValue(pidn, kCFNumberSInt32Type, &pid);
                if (name) cf_to_utf8(name, ev->window_title, sizeof(ev->window_title));
                if (owner) cf_to_utf8(owner, ev->process_name, sizeof(ev->process_name));
                ev->pid = pid;
                if (pid > 0) {
                    char path[PROC_PIDPATHINFO_MAXSIZE];
                    if (proc_pidpath(pid, path, sizeof(path)) > 0)
                        strncpy(ev->exe_path, path, sizeof(ev->exe_path) - 1);
                    /* 控件文本（Accessibility）*/
                    AXUIElementRef app = AXUIElementCreateApplication(pid);
                    if (app) {
                        AXUIElementRef el = NULL;
                        if (AXUIElementCopyElementAtPosition(app, loc.x, loc.y, &el) == kAXErrorSuccess && el) {
                            CFStringRef title = NULL;
                            if (AXUIElementCopyAttributeValue(el, kAXTitleAttribute,
                                    (CFTypeRef *)&title) == kAXErrorSuccess && title) {
                                cf_to_utf8(title, ev->control_text, sizeof(ev->control_text));
                                CFRelease(title);
                            }
                            CFRelease(el);
                        }
                        CFRelease(app);
                    }
                }
                break;
            }
        CFRelease(list);
    }
    ev->window_id = wid;   /* 冻结事件发生时所在窗口，供截图按此窗口截取 */
}
}

static CGEventRef event_tap_cb(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    step_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp = CFAbsoluteTimeGetCurrent() + UNIX_OFFSET;
    CGPoint loc = CGEventGetLocation(event);
    ev.cursor_x = (int)loc.x;
    ev.cursor_y = (int)loc.y;
    fill_context(&ev, loc);

    switch (type) {
    case kCGEventKeyDown: {
        int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        ev.kind = STEP_EVENT_KEY;
        ev.keycode = (int)kc;
        keycode_to_name((int)kc, ev.key_name, sizeof(ev.key_name));
        ev.mod_flags = (uint32_t)(CGEventGetFlags(event) &
            (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
             kCGEventFlagMaskAlternate | kCGEventFlagMaskShift));
        fill_key_text(&ev, event);
        break;
    }
        case kCGEventLeftMouseDown:
        case kCGEventRightMouseDown:
        case kCGEventOtherMouseDown: {
            int64_t btn = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            ev.kind = STEP_EVENT_MOUSE;
            ev.button = (int)btn;
            /* 相对位置：窗口模式下相对窗口，全屏模式下相对屏幕 */
            if (g_fullscreen) {
                CGRect sb = CGDisplayBounds(CGMainDisplayID());
                ev.rel_mode = 2;
                ev.rel_x_pct = clamp_pct((int)((loc.x - sb.origin.x) / sb.size.width  * 100));
                ev.rel_y_pct = clamp_pct((int)((loc.y - sb.origin.y) / sb.size.height * 100));
            } else {
                CGRect b; uint32_t wid = 0;
                if (window_at_point(loc, &b, &wid)) {
                    ev.rel_mode = 1;
                    ev.rel_x_pct = clamp_pct((int)((loc.x - b.origin.x) / b.size.width  * 100));
                    ev.rel_y_pct = clamp_pct((int)((loc.y - b.origin.y) / b.size.height * 100));
                } else {
                    ev.rel_mode = 0;
                }
            }
            break;
        }
        case kCGEventScrollWheel: {
            int64_t dy = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
            int64_t dx = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
            /* 触控板横向滑动（切换桌面）的整数 delta 有时为 0，补读定点 delta */
            if (dx == 0) {
                double f = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
                if (f != 0) dx = (int64_t)(f > 0 ? f + 0.5 : f - 0.5);
            }
            if (dy == 0) {
                double f = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
                if (f != 0) dy = (int64_t)(f > 0 ? f + 0.5 : f - 0.5);
            }
            ev.kind = STEP_EVENT_SCROLL;
            ev.scroll_dx = (int)dx;
            ev.scroll_dy = (int)dy;
            break;
        }
        default:
            return event;
    }
    if (g_cb) g_cb(&ev, g_ud);
    return event;
}

int os_start_capture(step_event_cb cb, void *userdata) {
    g_cb = cb; g_ud = userdata;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
                     | CGEventMaskBit(kCGEventLeftMouseDown)
                     | CGEventMaskBit(kCGEventRightMouseDown)
                     | CGEventMaskBit(kCGEventOtherMouseDown)
                     | CGEventMaskBit(kCGEventScrollWheel);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                             kCGEventTapOptionDefault, mask, event_tap_cb, NULL);
    if (!g_tap) return -1;
    g_src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), g_src, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);

    /* 启动焦点轮询：检测 Dock 启动应用、Mission Control 切换、Alt-Tab 等 */
    g_focus_baseline = 1;
    g_last_app[0] = '\0'; g_last_pid = -1; g_last_title[0] = '\0';
    g_focus_timer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES
                                                    block:^(NSTimer * _Nonnull t) {
        (void)t;
        poll_frontmost();
    }];
    return 0;
}

void os_stop_capture(void) {
    if (g_tap) {
        CGEventTapEnable(g_tap, false);
        if (g_src) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), g_src, kCFRunLoopCommonModes); CFRelease(g_src); g_src = NULL; }
        CFRelease(g_tap); g_tap = NULL;
    }
    if (g_focus_timer) { [g_focus_timer invalidate]; g_focus_timer = nil; }
    g_cb = NULL; g_ud = NULL;
}

/* ------------------------- 焦点轮询 ------------------------- */
static void poll_frontmost(void) {
    if (!g_cb) return;
    char app[256], title[256], exe[512];
    app[0] = title[0] = exe[0] = '\0';   /* 先置空，避免 API 未写入时残留垃圾 */
    int pid = 0;
    if (!os_get_frontmost_window(app, sizeof(app), title, sizeof(title), &pid, exe, sizeof(exe)))
        return;

    /* 跳过记录器自身（工具条/窗口获得焦点不应记为一次切换）*/
    if (pid == (int)getpid()) return;

    if (g_focus_baseline) {
        /* 仅记录基线，不生成步骤 */
        g_focus_baseline = 0;
        g_last_pid = pid;
        strncpy(g_last_app, app, sizeof(g_last_app) - 1);
        strncpy(g_last_title, title, sizeof(g_last_title) - 1);
        g_cand_pid = pid;
        strncpy(g_cand_app, app, sizeof(g_cand_app) - 1);
        strncpy(g_cand_title, title, sizeof(g_cand_title) - 1);
        return;
    }

    /* 同一应用（仅窗口标题变化，如终端目录/命令变化）-> 不记新切换，
       彻底消除标题抖动导致的重复/漏记 */
    if (pid == g_last_pid) return;

    /* 与候选 PID 一致 -> 连续两次轮询确认切换，生成 1 条 FOCUS */
    if (pid == g_cand_pid) {
        g_last_pid = pid;
        strncpy(g_last_app, app, sizeof(g_last_app) - 1);
        strncpy(g_last_title, title, sizeof(g_last_title) - 1);

        step_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.kind = STEP_EVENT_FOCUS;
        ev.timestamp = CFAbsoluteTimeGetCurrent() + UNIX_OFFSET;
        os_get_cursor(&ev.cursor_x, &ev.cursor_y);
        strncpy(ev.process_name, app, sizeof(ev.process_name) - 1);
        strncpy(ev.window_title, title, sizeof(ev.window_title) - 1);
        ev.pid = pid;
        strncpy(ev.exe_path, exe, sizeof(ev.exe_path) - 1);
        /* 冻结切换到的窗口 ID，使异步截图按 -l <wid> 截正确的窗口，
           避免快速切换时截到随后切到的窗口（如 Firefox 切到却截成 Chrome）*/
        ev.window_id = frontmost_window(NULL);
        g_cb(&ev, g_ud);
        return;
    }

    /* 不同应用 -> 设为候选，等下一次轮询确认（抑制单次抖动造成的重复记录）*/
    g_cand_pid = pid;
    strncpy(g_cand_app, app, sizeof(g_cand_app) - 1);
    strncpy(g_cand_title, title, sizeof(g_cand_title) - 1);
}

/* ------------------------- 帧环形缓冲（时间对齐） -------------------------
 * 后台以固定帧率持续抓整屏，每帧打 CFAbsoluteTime 时间戳存入环形缓冲。
 * 事件发生时不再「重新拍」，而是从缓冲里挑出事件时刻那一帧 → 截图时间与事件时间对齐。
 * 抓取用进程内 CGDisplayCreateImage（无 screencapture 子进程，延迟低），后台线程执行。
 */
#define FRAME_FPS       12
#define FRAME_CAP       (FRAME_FPS * 2)   /* 保留约 2 秒（足够：相关帧总在事件前 1 帧内）*/
#define FRAME_MAX_EDGE  1280              /* 降采样最长边（同时约束报告体积） */
#define FRAME_WEBP_Q    75.0f

typedef struct {
    uint8_t  *rgba;        /* 行优先 RGBA，顶向下（与屏幕一致），长度 w*h*4 */
    int       w, h;
    double    t;           /* CFAbsoluteTime（unix 秒） */
    uint32_t  wid;         /* 该帧最前台窗口 ID（FOCUS 选帧用） */
    CGRect    region;      /* 该帧对应的屏幕区域（光标定位用，屏幕坐标） */
} cap_frame_t;

static cap_frame_t   g_ring[FRAME_CAP];
static int           g_ring_head = 0;
static int           g_ring_count = 0;
static dispatch_queue_t g_capq = NULL;
static dispatch_source_t g_capsrc = NULL;

/* 进程内抓一帧整屏到 f（顶向下 RGBA，已降采样）。返回 1 成功。*/
static int capture_frame_into(cap_frame_t *f, CGDirectDisplayID disp) {
    CGImageRef img = CGDisplayCreateImage(disp);
    if (!img) return 0;
    int iw = (int)CGImageGetWidth(img);
    int ih = (int)CGImageGetHeight(img);
    int w = iw, h = ih;
    if (iw > FRAME_MAX_EDGE || ih > FRAME_MAX_EDGE) {
        double s = (double)FRAME_MAX_EDGE / (double)(iw > ih ? iw : ih);
        w = (int)(iw * s + 0.5); h = (int)(ih * s + 0.5);
    }
    if (w < 1) w = 1; if (h < 1) h = 1;
    uint8_t *rgba = (uint8_t *)malloc((size_t)w * h * 4);
    if (!rgba) { CGImageRelease(img); return 0; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGContextTranslateCTM(ctx, 0, h);          /* 翻转为顶向下，与屏幕一致 */
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(img);
    f->rgba = rgba; f->w = w; f->h = h;
    f->t = CFAbsoluteTimeGetCurrent() + UNIX_OFFSET;
    f->wid = frontmost_window(NULL);
    f->region = CGDisplayBounds(disp);
    return 1;
}

static void ring_push(void) {
    cap_frame_t *slot = &g_ring[g_ring_head];
    if (slot->rgba) free(slot->rgba);
    if (!capture_frame_into(slot, CGMainDisplayID())) {
        slot->rgba = NULL; slot->w = slot->h = 0; slot->t = 0;
        slot->wid = 0; slot->region = CGRectZero;
    }
    g_ring_head = (g_ring_head + 1) % FRAME_CAP;
    if (g_ring_count < FRAME_CAP) g_ring_count++;
}

/* 从新到旧选帧；FOCUS 时要求窗口已置顶到 ev->window_id。*/
static cap_frame_t *select_frame(const step_event_t *ev) {
    if (g_ring_count == 0) return NULL;
    double target = ev->timestamp;
    int start = (g_ring_head - 1 + FRAME_CAP) % FRAME_CAP;
    if (ev->kind == STEP_EVENT_FOCUS && ev->window_id) {
        for (int i = 0; i < g_ring_count; i++) {
            int idx = (start - i + FRAME_CAP * 2) % FRAME_CAP;
            cap_frame_t *f = &g_ring[idx];
            if (f->rgba && f->t <= target + 0.05 && f->wid == ev->window_id) return f;
        }
    }
    for (int i = 0; i < g_ring_count; i++) {
        int idx = (start - i + FRAME_CAP * 2) % FRAME_CAP;
        cap_frame_t *f = &g_ring[idx];
        if (f->rgba && f->t <= target) return f;
    }
    return &g_ring[start];
}

/* 立即抓包含 rect 中心的显示器（多显示器用）*/
static void capture_display_containing(CGRect rect, cap_frame_t *out) {
    memset(out, 0, sizeof(*out));
    CGDirectDisplayID disps[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, disps, &n);
    CGPoint ctr = CGPointMake(rect.origin.x + rect.size.width / 2,
                              rect.origin.y + rect.size.height / 2);
    CGDirectDisplayID chosen = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++)
        if (CGRectContainsPoint(CGDisplayBounds(disps[i]), ctr)) { chosen = disps[i]; break; }
    if (chosen == kCGNullDirectDisplay) chosen = CGMainDisplayID();
    capture_frame_into(out, chosen);
}

/* 拷贝整帧到新缓冲（work 拥有）*/
static void copy_frame(const cap_frame_t *src, cap_frame_t *dst) {
    size_t sz = (size_t)src->w * src->h * 4;
    dst->rgba = (uint8_t *)malloc(sz);
    memcpy(dst->rgba, src->rgba, sz);
    dst->w = src->w; dst->h = src->h; dst->t = src->t;
    dst->wid = src->wid; dst->region = src->region;
}

/* 裁剪 src 中 rect（src 坐标系，顶向下）到新缓冲（work 拥有）*/
static void crop_frame(const cap_frame_t *src, CGRect rect, cap_frame_t *dst) {
    int x = (int)floor(rect.origin.x), y = (int)floor(rect.origin.y);
    int cw = (int)ceil(rect.size.width), ch = (int)ceil(rect.size.height);
    if (x < 0) x = 0; if (y < 0) y = 0;
    if (x + cw > src->w) cw = src->w - x;
    if (y + ch > src->h) ch = src->h - y;
    if (cw < 1) cw = 1; if (ch < 1) ch = 1;
    dst->rgba = (uint8_t *)malloc((size_t)cw * ch * 4);
    for (int r = 0; r < ch; r++)
        memcpy(dst->rgba + (size_t)r * cw * 4,
               src->rgba + (size_t)(y + r) * src->w * 4 + (size_t)x * 4,
               (size_t)cw * 4);
    dst->w = cw; dst->h = ch; dst->t = src->t;
    dst->wid = src->wid; dst->region = rect;
}

/* 为事件准备最终要合成的帧（裁剪/多显示器），结果写入 work（rgba 由 work 拥有）*/
static int prepare_work_frame(const step_event_t *ev, cap_frame_t *work) {
    cap_frame_t *sel = select_frame(ev);
    if (!sel || !sel->rgba) {
        if (!capture_frame_into(work, CGMainDisplayID())) return 0;
        return 1;
    }
    int is_window = (!g_fullscreen && ev->window_id);
    if (is_window) {
        CGRect wb;
        if (window_bounds(ev->window_id, &wb)) {
            CGRect mb = CGDisplayBounds(CGMainDisplayID());
            if (!CGRectIntersectsRect(mb, wb)) {
                capture_display_containing(wb, work);
                if (!work->rgba) return 0;
                work->region = wb;     /* 光标定位用窗口屏幕坐标 */
                return 1;
            }
            double sx = (double)sel->w / mb.size.width;
            double sy = (double)sel->h / mb.size.height;
            CGRect cr = CGRectMake((wb.origin.x - mb.origin.x) * sx,
                                   (wb.origin.y - mb.origin.y) * sy,
                                   wb.size.width * sx, wb.size.height * sy);
            crop_frame(sel, cr, work);
            work->region = wb;         /* 光标定位用窗口屏幕坐标 */
            return 1;
        }
    }
    copy_frame(sel, work);
    return 1;
}

/* 主线程：把 work 合成光标/标记并编码为 WebP（webp 由调用方 free）*/
static void composite_nsimage(cap_frame_t *work, int cx, int cy,
                              const char *marker, uint8_t **out_webp, size_t *out_len) {
    *out_webp = NULL; *out_len = 0;
    @autoreleasepool {
        NSBitmapImageRep *brep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:(unsigned char **)&work->rgba
            pixelsWide:work->w pixelsHigh:work->h bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:work->w * 4 bitsPerPixel:32];
        NSImage *base = [[NSImage alloc] init];
        [base addRepresentation:brep];

        NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(work->w, work->h)];
        [out lockFocus];
        [base drawAtPoint:NSMakePoint(0, 0) fromRect:NSZeroRect
                 operation:NSCompositingOperationCopy fraction:1.0];

        NSCursor *cur = [NSCursor currentCursor];
        if (!cur) cur = [NSCursor arrowCursor];
        NSImage *cimg = [cur image];
        NSPoint hot = [cur hotSpot];
        NSPoint dp = NSMakePoint(cx - work->region.origin.x - hot.x,
                                 cy - work->region.origin.y - hot.y);
        if (cimg)
            [cimg drawAtPoint:dp fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver fraction:1.0];

        if (marker && marker[0]) {
            NSString *ms = [NSString stringWithUTF8String:marker];
            NSDictionary *attr = @{
                NSFontAttributeName: [NSFont systemFontOfSize:13],
                NSForegroundColorAttributeName: [NSColor whiteColor]
            };
            NSSize ts = [ms sizeWithAttributes:attr];
            NSRect bg = NSMakeRect(dp.x + (cimg ? cimg.size.width : 0) + 4, dp.y,
                                   ts.width + 8, ts.height + 4);
            [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.6] setFill];
            NSRectFill(bg);
            [ms drawAtPoint:NSMakePoint(bg.origin.x + 4, bg.origin.y + 2)
              withAttributes:attr];
        }
        [out unlockFocus];

        CGImageRef ocg = [out CGImageForProposedRect:NULL context:nil hints:nil];
        if (ocg) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:ocg];
            int w = (int)[rep pixelsWide], h = (int)[rep pixelsHigh];
            int bpr = (int)[rep bytesPerRow];
            const uint8_t *src = [rep bitmapData];
            uint8_t *tight = (uint8_t *)malloc((size_t)w * h * 4);
            for (int y = 0; y < h; y++)
                memcpy(tight + (size_t)y * w * 4,
                       src + (size_t)y * bpr, (size_t)w * 4);
            uint8_t *webp = NULL;
            size_t n = WebPEncodeRGBA(tight, w, h, w * 4, FRAME_WEBP_Q, &webp);
            free(tight);
            if (n) { *out_webp = webp; *out_len = n; }
            else if (webp) free(webp);
        }
    }
}

void os_frame_capture_start(void) {
    if (g_capq) return;
    g_capq = dispatch_queue_create("kaca.capture", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_capq, ^{ ring_push(); });   /* 立即抓一帧，避免启动时空缓冲 */
    g_capsrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_capq);
    if (g_capsrc) {
        uint64_t iv = NSEC_PER_SEC / FRAME_FPS;
        dispatch_source_set_timer(g_capsrc,
            dispatch_time(DISPATCH_TIME_NOW, iv), iv, iv / 2);
        dispatch_source_set_event_handler(g_capsrc, ^{ ring_push(); });
        dispatch_resume(g_capsrc);
    }
}

void os_frame_capture_stop(void) {
    if (g_capsrc) { dispatch_source_cancel(g_capsrc); g_capsrc = NULL; }
    if (g_capq) {
        dispatch_sync(g_capq, ^{});   /* 排空剩余抓取块 */
        g_capq = NULL;
    }
    for (int i = 0; i < FRAME_CAP; i++) {
        if (g_ring[i].rgba) free(g_ring[i].rgba);
        g_ring[i].rgba = NULL;
    }
    g_ring_count = 0; g_ring_head = 0;
}

/* 按事件时间取帧 → 裁剪 → 主线程合成光标/标记 → WebP 异步回调。
 * 选帧在后台队列完成（不阻塞事件分发）；合成在主队列（依赖 AppKit）。*/
void os_grab_frame_for_event(const step_event_t *ev, const char *op_marker,
                             void (*cb)(uint8_t *data, size_t len, void *ud), void *ud) {
    step_event_t *e = (step_event_t *)malloc(sizeof(*e));
    if (!e) { cb(NULL, 0, ud); return; }
    *e = *ev;
    char *m = op_marker ? strdup(op_marker) : NULL;
    dispatch_queue_t q = g_capq ? g_capq : dispatch_get_global_queue(0, 0);
    dispatch_async(q, ^{
        __block cap_frame_t work; memset(&work, 0, sizeof(work));
        int ok = prepare_work_frame(e, &work);
        if (ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                uint8_t *webp = NULL; size_t len = 0;
                composite_nsimage(&work, e->cursor_x, e->cursor_y, m, &webp, &len);
                cb(webp, len, ud);
                if (work.rgba) free(work.rgba);
            });
        } else {
            cb(NULL, 0, ud);
        }
        free(e); free(m);
    });
}

void os_get_cursor(int *x, int *y) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    *x = (int)p.x;
    *y = (int)p.y;
}

int os_get_frontmost_window(char *app, size_t app_n,
                            char *title, size_t title_n,
                            int *pid, char *exe, size_t exe_n) {
    @autoreleasepool {
        NSRunningApplication *ra = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (!ra) return 0;
        if (app && app_n) {
            NSString *n = [ra localizedName];
            if (n) { strncpy(app, [n UTF8String], app_n - 1); app[app_n - 1] = '\0'; }
        }
        if (pid) *pid = (int)[ra processIdentifier];
        if (exe && exe_n) {
            NSString *p = [[ra executableURL] path];
            if (p) { strncpy(exe, [p UTF8String], exe_n - 1); exe[exe_n - 1] = '\0'; }
        }
        if (title && title_n) {
            title[0] = '\0';   /* 先置空，避免 AX 失败时残留垃圾 */
            AXUIElementRef appref = AXUIElementCreateApplication([ra processIdentifier]);
            if (appref) {
                CFTypeRef win = NULL;
                if (AXUIElementCopyAttributeValue(appref, kAXFocusedWindowAttribute,
                                                  &win) == kAXErrorSuccess && win) {
                    CFStringRef t = NULL;
                    if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute,
                            (CFTypeRef *)&t) == kAXErrorSuccess && t) {
                        cf_to_utf8(t, title, title_n);
                        CFRelease(t);
                    }
                    CFRelease(win);
                }
                CFRelease(appref);
            }
        }
        return 1;
    }
}

/* 泵主 run loop，用于停止录制后把排队的异步截图块跑完 */
void os_drain_main(void) {
    if ([NSThread isMainThread])
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
}

/* ------------------------- 系统信息 ------------------------- */
int os_get_system_info(system_info_t *out) {
    memset(out, 0, sizeof(*out));
    snprintf(out->os_name, sizeof(out->os_name), "macOS");

    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    snprintf(out->os_version, sizeof(out->os_version), "%ld.%ld.%ld",
             (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);

    char buf[256]; size_t len;
    len = sizeof(buf);
    if (sysctlbyname("machdep.cpu.brand_string", buf, &len, NULL, 0) == 0)
        strncpy(out->cpu_brand, buf, sizeof(out->cpu_brand) - 1);
    len = sizeof(out->cpu_cores);
    if (sysctlbyname("hw.logicalcpu", &out->cpu_cores, &len, NULL, 0) != 0)
        out->cpu_cores = 0;
    len = sizeof(out->mem_bytes);
    sysctlbyname("hw.memsize", &out->mem_bytes, &len, NULL, 0);
    gethostname(out->hostname, sizeof(out->hostname) - 1);
    return 0;
}

/* ------------------------- 主线程派发 ------------------------- */
void os_run_on_main(void (*fn)(void *), void *arg) {
    if ([NSThread isMainThread]) { fn(arg); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ fn(arg); });
}

void os_open_accessibility_settings(void) {
    @autoreleasepool {
        NSURL *u = [NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [[NSWorkspace sharedWorkspace] openURL:u];
    }
}
