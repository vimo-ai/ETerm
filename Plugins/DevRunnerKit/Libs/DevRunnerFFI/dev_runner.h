/* Warning: derived from cbindgen output. Cleaned for C compatibility. */

#ifndef DEV_RUNNER_H
#define DEV_RUNNER_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct DevRunnerHandle DevRunnerHandle;

struct DevRunnerHandle *dev_runner_init(void);
void dev_runner_free(struct DevRunnerHandle *handle);
void dev_runner_free_string(char *ptr);

char *dev_runner_detect(const char *path, char **out_error);
char *dev_runner_scan(const char *path, char **out_error);

char *dev_runner_open(struct DevRunnerHandle *handle, const char *project_path, char **out_error);
bool dev_runner_close(struct DevRunnerHandle *handle, const char *project_path, char **out_error);
char *dev_runner_list_opened(const struct DevRunnerHandle *handle, char **out_error);

char *dev_runner_list_targets(const struct DevRunnerHandle *handle,
                              const char *project_path,
                              char **out_error);

char *dev_runner_list_devices(const struct DevRunnerHandle *handle,
                              const char *project_path,
                              char **out_error);

char *dev_runner_build_cmd(const struct DevRunnerHandle *handle,
                           const char *project_path,
                           const char *target,
                           const char *options_json,
                           char **out_error);

char *dev_runner_install_cmd(const struct DevRunnerHandle *handle,
                             const char *project_path,
                             const char *target,
                             const char *options_json,
                             char **out_error);

char *dev_runner_run_cmd(const struct DevRunnerHandle *handle,
                         const char *project_path,
                         const char *target,
                         const char *options_json,
                         char **out_error);

char *dev_runner_log_cmd(const struct DevRunnerHandle *handle,
                         const char *project_path,
                         const char *target,
                         const char *options_json,
                         char **out_error);

char *dev_runner_start_monitored(struct DevRunnerHandle *handle,
                                 const char *project_path,
                                 const char *target,
                                 const char *command_json,
                                 char **out_error);

bool dev_runner_stop_process(struct DevRunnerHandle *handle,
                             const char *process_id,
                             char **out_error);

char *dev_runner_list_processes(const struct DevRunnerHandle *handle, char **out_error);

char *dev_runner_get_process(const struct DevRunnerHandle *handle,
                             const char *process_id,
                             char **out_error);

char *dev_runner_get_metrics(struct DevRunnerHandle *handle, uint32_t pid, char **out_error);

#endif /* DEV_RUNNER_H */
