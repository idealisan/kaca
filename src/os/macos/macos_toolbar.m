/*
 * macOS 工具条 UI（AppKit）。横向条状，可置顶。
 */
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "os/os_api.h"
#include <stdlib.h>

static toolbar_cb g_on_start = NULL, g_on_stop = NULL;
static double (*g_tick)(void) = NULL;
static int g_recording = 0;

static NSWindow    *g_win = NULL;
static NSTextField *g_status = NULL;
static NSTextField *g_elapsed = NULL;
static NSButton    *g_startBtn = NULL;
static NSButton    *g_stopBtn = NULL;
static NSPopUpButton *g_modePopup = NULL;
@class AppDelegate;
static AppDelegate *g_delegate = NULL;   /* 强引用，避免 NSApp 不持有 delegate 而被释放 */

/* 关闭工具条窗口即退出进程（小工具不应滞留）*/
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender; return YES;
}
@end

@interface TBar : NSObject
- (void)onTick:(NSTimer *)t;
- (void)doStart:(id)s;
- (void)doStop:(id)s;
- (void)doMode:(id)s;
@end

@implementation TBar
- (void)onTick:(NSTimer *)t {
    (void)t;
    if (g_recording && g_tick) {
        double e = g_tick();
        long s = (long)e, h = s / 3600, m = (s % 3600) / 60, ss = s % 60;
        g_elapsed.stringValue = [NSString stringWithFormat:@"%02ld:%02ld:%02ld", h, m, ss];
    }
}
- (void)doStart:(id)s { (void)s; if (g_on_start) g_on_start(); }
- (void)doStop:(id)s  { (void)s; if (g_on_stop)  g_on_stop(); }
- (void)doMode:(id)s  {
    (void)s;
    if (g_modePopup) {
        BOOL fs = [[g_modePopup titleOfSelectedItem] isEqualToString:@"全屏"];
        os_set_capture_mode(fs ? 1 : 0);
    }
}
@end

int os_show_toolbar(toolbar_cb on_start, toolbar_cb on_stop) {
    g_on_start = on_start; g_on_stop = on_stop;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    g_delegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:g_delegate];

    TBar *bar = [[TBar alloc] init];

    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat w = 500, h = 48;
    NSRect r = NSMakeRect((screen.size.width - w) / 2,
                          screen.size.height - h - 12, w, h);

    g_win = [[NSWindow alloc] initWithContentRect:r
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  | NSWindowStyleMaskMiniaturizable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    [g_win setLevel:NSFloatingWindowLevel];
    [g_win setTitle:@"步骤记录器"];

    NSView *v = g_win.contentView;

    g_status = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 14, 110, 20)];
    [g_status setBezeled:NO]; [g_status setDrawsBackground:NO];
    [g_status setEditable:NO]; [g_status setSelectable:NO];
    [g_status setStringValue:@"○ 待命"];
    [g_status setFont:[NSFont systemFontOfSize:13]];
    [v addSubview:g_status];

    g_elapsed = [[NSTextField alloc] initWithFrame:NSMakeRect(120, 14, 90, 20)];
    [g_elapsed setBezeled:NO]; [g_elapsed setDrawsBackground:NO];
    [g_elapsed setEditable:NO]; [g_elapsed setSelectable:NO];
    [g_elapsed setStringValue:@"00:00:00"];
    [v addSubview:g_elapsed];

    g_startBtn = [NSButton buttonWithTitle:@"▶ 开始录制"
                                    target:bar action:@selector(doStart:)];
    [g_startBtn setFrame:NSMakeRect(215, 11, 110, 26)];
    [v addSubview:g_startBtn];

    g_stopBtn = [NSButton buttonWithTitle:@"■ 停止"
                                   target:bar action:@selector(doStop:)];
    [g_stopBtn setFrame:NSMakeRect(330, 11, 80, 26)];
    [g_stopBtn setEnabled:NO];
    [v addSubview:g_stopBtn];

    g_modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(415, 11, 80, 26)
                                             pullsDown:NO];
    [g_modePopup addItemWithTitle:@"窗口"];
    [g_modePopup addItemWithTitle:@"全屏"];
    [g_modePopup selectItemWithTitle:[NSString stringWithUTF8String:os_capture_mode_label()]];
    [g_modePopup setTarget:bar];
    [g_modePopup setAction:@selector(doMode:)];
    [v addSubview:g_modePopup];

    [NSTimer scheduledTimerWithTimeInterval:0.5 target:bar
                                   selector:@selector(onTick:)
                                   userInfo:nil repeats:YES];

    [g_win makeKeyAndOrderFront:nil];
    [NSApp run];
    return 0;
}

void os_set_recording_state(int recording) {
    g_recording = recording;
    g_status.stringValue = recording ? @"● 录制中" : @"○ 待命";
    [g_startBtn setEnabled:!recording];
    [g_stopBtn setEnabled:recording];
    if (!recording) g_elapsed.stringValue = @"00:00:00";
}

void os_set_tick_callback(double (*cb)(void)) { g_tick = cb; }
void os_hide_toolbar(void) { if (g_win) { [g_win close]; g_win = nil; } }

char *os_show_save_dialog(const char *default_name) {
    @autoreleasepool {
        NSSavePanel *sp = [NSSavePanel savePanel];
        NSString *def = default_name ? [NSString stringWithUTF8String:default_name]
                                      : @"step-report.html";
        [sp setNameFieldStringValue:def];
        if (@available(macOS 11.0, *))
            [sp setAllowedContentTypes:@[UTTypeHTML]];
        [sp setCanCreateDirectories:YES];
        if ([sp runModal] != NSModalResponseOK) return NULL;
        NSString *path = [[sp URL] path];
        if (!path) return NULL;
        return strdup([path UTF8String]);
    }
}
