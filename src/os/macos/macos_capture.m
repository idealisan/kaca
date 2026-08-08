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
#import <sys/sysctl.h>
#import <sys/time.h>
#import <libproc.h>

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

static int g_fullscreen = 0;  /* 0=当前窗口 1=全屏 */

void os_toggle_capture_mode(void) { g_fullscreen = g_fullscreen ? 0 : 1; }
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

/* 找到光标所在窗口，返回其 rect 与 windowID（找不到返回 0）*/
static int window_at_point(CGPoint loc, CGRect *outBounds, uint32_t *outWin) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;
    int found = 0;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFDictionaryRef bdict = CFDictionaryGetValue(d, kCGWindowBounds);
        if (!bdict) continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation(bdict, &b)) continue;
        if (!CGRectContainsPoint(b, loc)) continue;

        CFNumberRef num = CFDictionaryGetValue(d, kCGWindowNumber);
        uint32_t wid = 0;
        if (num) CFNumberGetValue(num, kCFNumberSInt32Type, &wid);
        *outBounds = b;
        *outWin = wid;
        found = 1;
        /* 取第一个命中的即可（一般是最靠前的）*/
        break;
    }
    CFRelease(list);
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
                if (name) {
                    const char *c = CFStringGetCStringPtr(name, kCFStringEncodingUTF8);
                    if (c) strncpy(ev->window_title, c, sizeof(ev->window_title) - 1);
                }
                if (owner) {
                    const char *c = CFStringGetCStringPtr(owner, kCFStringEncodingUTF8);
                    if (c) strncpy(ev->process_name, c, sizeof(ev->process_name) - 1);
                }
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
                                const char *c = CFStringGetCStringPtr(title, kCFStringEncodingUTF8);
                                if (c) strncpy(ev->control_text, c, sizeof(ev->control_text) - 1);
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
            break;
        }
        case kCGEventLeftMouseDown:
        case kCGEventRightMouseDown:
        case kCGEventOtherMouseDown: {
            int64_t btn = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            ev.kind = STEP_EVENT_MOUSE;
            ev.button = (int)btn;
            break;
        }
        case kCGEventScrollWheel: {
            int64_t dy = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
            int64_t dx = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
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
    return 0;
}

void os_stop_capture(void) {
    if (g_tap) {
        CGEventTapEnable(g_tap, false);
        if (g_src) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), g_src, kCFRunLoopCommonModes); CFRelease(g_src); g_src = NULL; }
        CFRelease(g_tap); g_tap = NULL;
    }
    g_cb = NULL; g_ud = NULL;
}

/* ------------------------- 截图合成 ------------------------- */

/* 通过系统 screencapture 命令抓取屏幕/窗口（macOS 15+ 已移除旧 CG 截图 API）*/
static NSImage *grab_screenshot(int fs, uint32_t wid) {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"kaca_%lld.png",
                                   (long long)(CFAbsoluteTimeGetCurrent() * 1000.0)]];
    NSImage *im = nil;
    @autoreleasepool {
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-x", @"-t", @"png", nil];
        if (!fs) {
            [args addObject:@"-l"];
            [args addObject:[NSString stringWithFormat:@"%u", wid]];
        }
        [args addObject:tmp];
        t.arguments = args;
        [t launch];
        [t waitUntilExit];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tmp]) {
            im = [[NSImage alloc] initWithContentsOfFile:tmp];
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    }
    return im;
}

int os_capture_screenshot(const step_event_t *ev, const char *op_marker,
                          uint8_t **out_png, size_t *out_len) {
    *out_png = NULL; *out_len = 0;
    CGPoint loc = CGPointMake(ev ? ev->cursor_x : 0, ev ? ev->cursor_y : 0);

    int fs = g_fullscreen;
    CGRect bounds; uint32_t wid = 0;
    if (!fs && window_at_point(loc, &bounds, &wid)) {
        /* 用窗口截图 */
    } else {
        fs = 1;
        bounds = CGDisplayBounds(CGMainDisplayID());
    }

    NSImage *src = grab_screenshot(fs, wid);
    if (!src) return -1;

    @autoreleasepool {
        NSSize sz = [src size];
        NSImage *out = [[NSImage alloc] initWithSize:sz];
        [out lockFocus];
        [src drawAtPoint:NSMakePoint(0, 0) fromRect:NSZeroRect
               operation:NSCompositingOperationCopy fraction:1.0];

        NSCursor *cur = [NSCursor currentCursor];
        if (!cur) cur = [NSCursor arrowCursor];
        NSImage *cimg = [cur image];
        NSPoint hot = [cur hotSpot];
        NSPoint dp = NSMakePoint(loc.x - bounds.origin.x - hot.x,
                                 loc.y - bounds.origin.y - hot.y);
        if (cimg)
            [cimg drawAtPoint:dp fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver fraction:1.0];

        if (op_marker && op_marker[0]) {
            NSString *ms = [NSString stringWithUTF8String:op_marker];
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
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:ocg];
        NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (data) {
            *out_png = (uint8_t *)malloc([data length]);
            if (*out_png) {
                memcpy(*out_png, [data bytes], [data length]);
                *out_len = [data length];
            }
        }
    }
    return (*out_png != NULL) ? 0 : -1;
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
