#ifndef RECORDER_H
#define RECORDER_H

#include "os/os_api.h"

#ifdef __cplusplus
extern "C" {
#endif

void recorder_init(void);
void recorder_free(void);

void recorder_start(void);
void recorder_stop(void);

/* 平台层事件捕获的回调入口（符合 step_event_cb 签名）*/
void recorder_handle_event(const step_event_t *ev, void *userdata);

/* 当前已录制时长（秒），供工具条刷新 */
double recorder_elapsed(void);

/* 生成并保存报告到默认路径（~/Desktop），返回路径指针（静态缓冲）或 NULL */
const char *recorder_save_default(void);

#ifdef __cplusplus
}
#endif

#endif /* RECORDER_H */
