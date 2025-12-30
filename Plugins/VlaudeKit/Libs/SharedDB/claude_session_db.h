#ifndef CLAUDE_SESSION_DB_H
#define CLAUDE_SESSION_DB_H

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/**
 * FFI 友好的错误码
 */
typedef enum SessionDbError {
    Success = 0,
    NullPointer = 1,
    InvalidUtf8 = 2,
    DatabaseError = 3,
    CoordinationError = 4,
    PermissionDenied = 5,
    Unknown = 99,
} SessionDbError;

/**
 * 不透明句柄
 */
typedef struct SessionDbHandle SessionDbHandle;

/**
 * Project C 结构体
 */
typedef struct Project {
    int64_t id;
    char *name;
    char *path;
    char *source;
    int64_t created_at;
    int64_t updated_at;
} Project;

/**
 * C 数组 wrapper
 */
typedef struct ProjectArray {
    struct Project *data;
    uintptr_t len;
} ProjectArray;

/**
 * Session C 结构体
 */
typedef struct Session {
    int64_t id;
    char *session_id;
    int64_t project_id;
    int64_t message_count;
    int64_t last_message_at;
    int64_t created_at;
    int64_t updated_at;
} Session;

/**
 * C 数组 wrapper
 */
typedef struct SessionArray {
    struct Session *data;
    uintptr_t len;
} SessionArray;

/**
 * Message C 输入结构体
 */
typedef struct MessageInputC {
    const char *uuid;
    int32_t role;
    const char *content;
    int64_t timestamp;
    int64_t sequence;
} MessageInputC;

/**
 * Message C 输出结构体
 */
typedef struct MessageC {
    int64_t id;
    char *session_id;
    char *uuid;
    int32_t role;
    char *content;
    int64_t timestamp;
    int64_t sequence;
} MessageC;

/**
 * C 数组 wrapper
 */
typedef struct MessageArray {
    struct MessageC *data;
    uintptr_t len;
} MessageArray;

/**
 * SearchResult C 结构体
 */
typedef struct SearchResultC {
    int64_t message_id;
    char *session_id;
    int64_t project_id;
    char *project_name;
    char *role;
    char *content;
    char *snippet;
    double score;
    int64_t timestamp;
} SearchResultC;

/**
 * C 数组 wrapper
 */
typedef struct SearchResultArray {
    struct SearchResultC *data;
    uintptr_t len;
} SearchResultArray;

/**
 * 连接数据库
 *
 * # Safety
 * `path` 必须是有效的 C 字符串
 */
enum SessionDbError session_db_connect(const char *path, struct SessionDbHandle **out_handle);

/**
 * 关闭数据库连接
 *
 * # Safety
 * `handle` 必须是 `session_db_connect` 返回的有效句柄
 */
void session_db_close(struct SessionDbHandle *handle);

/**
 * 注册为 Writer
 *
 * # Safety
 * `handle` 必须是有效句柄
 */
enum SessionDbError session_db_register_writer(struct SessionDbHandle *handle,
                                               int32_t writer_type,
                                               int32_t *out_role);

/**
 * 心跳
 *
 * # Safety
 * `handle` 必须是有效句柄
 */
enum SessionDbError session_db_heartbeat(struct SessionDbHandle *handle);

/**
 * 释放 Writer
 *
 * # Safety
 * `handle` 必须是有效句柄
 */
enum SessionDbError session_db_release_writer(struct SessionDbHandle *handle);

/**
 * 检查 Writer 健康状态
 *
 * # Safety
 * `handle` 必须是有效句柄
 * `out_health` 输出健康状态: 0=Alive, 1=Timeout, 2=Released
 */
enum SessionDbError session_db_check_writer_health(const struct SessionDbHandle *handle,
                                                   int32_t *out_health);

/**
 * 尝试接管 Writer (Reader 在检测到超时后调用)
 *
 * # Safety
 * `handle` 必须是有效句柄
 * `out_taken` 输出是否接管成功: 1=成功, 0=失败
 */
enum SessionDbError session_db_try_takeover(struct SessionDbHandle *handle,
                                            int32_t *out_taken);

/**
 * 获取统计信息
 *
 * # Safety
 * `handle` 必须是有效句柄
 */
enum SessionDbError session_db_get_stats(const struct SessionDbHandle *handle,
                                         int64_t *out_projects,
                                         int64_t *out_sessions,
                                         int64_t *out_messages);

/**
 * 获取或创建 Project
 *
 * # Safety
 * `handle`, `name`, `path`, `source` 必须是有效的 C 字符串
 */
enum SessionDbError session_db_upsert_project(struct SessionDbHandle *handle,
                                              const char *name,
                                              const char *path,
                                              const char *source,
                                              int64_t *out_id);

/**
 * 列出所有 Projects
 *
 * # Safety
 * `handle` 必须是有效句柄，返回的数组需要调用 `session_db_free_projects` 释放
 */
enum SessionDbError session_db_list_projects(const struct SessionDbHandle *handle,
                                             struct ProjectArray **out_array);

/**
 * 释放 Projects 数组
 *
 * # Safety
 * `array` 必须是 `session_db_list_projects` 返回的有效指针
 */
void session_db_free_projects(struct ProjectArray *array);

/**
 * 创建或更新 Session
 *
 * # Safety
 * `handle`, `session_id` 必须是有效的 C 字符串
 */
enum SessionDbError session_db_upsert_session(struct SessionDbHandle *handle,
                                              const char *session_id,
                                              int64_t project_id);

/**
 * 列出 Project 的 Sessions
 *
 * # Safety
 * `handle` 必须是有效句柄，返回的数组需要调用 `session_db_free_sessions` 释放
 */
enum SessionDbError session_db_list_sessions(const struct SessionDbHandle *handle,
                                             int64_t project_id,
                                             struct SessionArray **out_array);

/**
 * 释放 Sessions 数组
 *
 * # Safety
 * `array` 必须是 `session_db_list_sessions` 返回的有效指针
 */
void session_db_free_sessions(struct SessionArray *array);

/**
 * 获取 session 的扫描检查点
 *
 * # Safety
 * `handle`, `session_id` 必须是有效的 C 字符串
 */
enum SessionDbError session_db_get_scan_checkpoint(const struct SessionDbHandle *handle,
                                                   const char *session_id,
                                                   int64_t *out_timestamp);

/**
 * 更新 session 的最后消息时间
 *
 * # Safety
 * `handle`, `session_id` 必须是有效的 C 字符串
 */
enum SessionDbError session_db_update_session_last_message(struct SessionDbHandle *handle,
                                                           const char *session_id,
                                                           int64_t timestamp);

/**
 * 批量插入 Messages
 *
 * # Safety
 * `handle`, `session_id`, `messages` 必须是有效指针
 */
enum SessionDbError session_db_insert_messages(struct SessionDbHandle *handle,
                                               const char *session_id,
                                               const struct MessageInputC *messages,
                                               uintptr_t message_count,
                                               uintptr_t *out_inserted);

/**
 * 列出 Session 的 Messages
 *
 * # Safety
 * `handle`, `session_id` 必须是有效指针，返回的数组需要调用 `session_db_free_messages` 释放
 */
enum SessionDbError session_db_list_messages(const struct SessionDbHandle *handle,
                                             const char *session_id,
                                             uintptr_t limit,
                                             uintptr_t offset,
                                             struct MessageArray **out_array);

/**
 * 释放 Messages 数组
 *
 * # Safety
 * `array` 必须是 `session_db_list_messages` 返回的有效指针
 */
void session_db_free_messages(struct MessageArray *array);

/**
 * FTS5 全文搜索
 *
 * # Safety
 * `handle`, `query` 必须是有效指针，返回的数组需要调用 `session_db_free_search_results` 释放
 */
enum SessionDbError session_db_search_fts(const struct SessionDbHandle *handle,
                                          const char *query,
                                          uintptr_t limit,
                                          struct SearchResultArray **out_array);

/**
 * FTS5 全文搜索 (限定 Project)
 *
 * # Safety
 * `handle`, `query` 必须是有效指针，返回的数组需要调用 `session_db_free_search_results` 释放
 */
enum SessionDbError session_db_search_fts_with_project(const struct SessionDbHandle *handle,
                                                       const char *query,
                                                       uintptr_t limit,
                                                       int64_t project_id,
                                                       struct SearchResultArray **out_array);

/**
 * 释放 SearchResults 数组
 *
 * # Safety
 * `array` 必须是 `session_db_search_fts*` 返回的有效指针
 */
void session_db_free_search_results(struct SearchResultArray *array);

/**
 * 释放 C 字符串
 *
 * # Safety
 * `s` 必须是由本库创建的 C 字符串
 */
void session_db_free_string(char *s);

#endif  /* CLAUDE_SESSION_DB_H */
