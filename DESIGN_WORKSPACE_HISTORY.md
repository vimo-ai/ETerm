# Workspace History 设计文档

## 1. 概述

### 1.1 目标

为 ETerm 工作区提供文件系统级别的快照功能，防止：
- 误操作（如 `rm -rf`、错误的 `ln -s`）导致文件丢失
- Claude 编辑代码过程中改崩了无法回滚
- 对话 resume 后丢失上下文，无法恢复到之前的工作状态

### 1.2 设计原则

- **插件化**：核心快照功能作为独立插件，其他插件可依赖调用
- **简单优先**：先实现可用的 MVP，后续再优化（如 CAS 去重）
- **不污染项目**：历史数据存储在全局目录，不影响项目结构

## 2. 架构设计

### 2.1 插件拓扑

```
┌─────────────────────────────────────────────────┐
│  Plugin A: WorkspaceHistory                     │
│  ├── 定时快照（每 5 分钟）                        │
│  ├── API: snapshot / list / restore / diff      │
│  └── 存储管理 + 清理策略                          │
└─────────────────────────────────────────────────┘
                    ▲
                    │ 依赖
┌─────────────────────────────────────────────────┐
│  Plugin B: ClaudeGuard                          │
│  ├── 依赖: WorkspaceHistory                      │
│  └── 在 Claude hooks 节点调用快照 API             │
└─────────────────────────────────────────────────┘
                    ▲
                    │ 可选依赖
┌─────────────────────────────────────────────────┐
│  Plugin C: ShellGuard (未来)                     │
│  └── 危险命令执行前调用快照 API                    │
└─────────────────────────────────────────────────┘
```

### 2.2 数据流

```
触发快照
    │
    ▼
扫描工作目录
    │
    ▼
对比上一个 manifest（mtime + size）
    │
    ├── 未变化 → 记录引用
    │
    └── 已变化 → 压缩存储 + 记录
    │
    ▼
保存 manifest
    │
    ▼
触发清理（异步）
```

## 3. 存储设计

### 3.1 存储路径

```
~/.eterm/
└── history/
    └── <project-hash>/           # sha256(project-path).prefix(16)
        ├── meta.json             # 项目元信息
        ├── snapshots/
        │   ├── <timestamp>/      # 毫秒时间戳
        │   │   ├── manifest.json
        │   │   └── files/
        │   │       ├── src%2Fmain.swift.gz
        │   │       └── ...
        │   └── <timestamp>/
        │       └── ...
        └── index.db              # SQLite 索引（可选，用于快速查询）
```

### 3.2 Project Hash 计算

```swift
func projectHash(for path: URL) -> String {
    let normalized = path.standardizedFileURL.path
    let hash = SHA256.hash(data: normalized.data(using: .utf8)!)
    return hash.prefix(16).hexString
}
```

### 3.3 meta.json

```json
{
    "projectPath": "/Users/xxx/project",
    "createdAt": 1703145600000,
    "lastSnapshotAt": 1703149200000,
    "totalSnapshots": 42
}
```

### 3.4 manifest.json

```json
{
    "id": "1703145600000",
    "timestamp": 1703145600000,
    "label": "claude-session-start",
    "source": "claude-guard",
    "baseSnapshot": "1703145300000",
    "files": [
        {
            "path": "src/main.swift",
            "size": 1234,
            "mtime": 1703145590,
            "mode": 33188,
            "stored": true
        },
        {
            "path": "src/utils.swift",
            "size": 567,
            "mtime": 1703145000,
            "mode": 33188,
            "stored": false,
            "reference": "1703145300000"
        }
    ],
    "stats": {
        "totalFiles": 150,
        "changedFiles": 2,
        "storedSize": 2048
    }
}
```

**字段说明**：
- `stored: true` - 文件内容存储在当前快照的 `files/` 目录
- `stored: false` - 文件未变化，从 `reference` 指向的快照读取
- `mode` - Unix 文件权限（保留可执行位等）

## 4. API 设计

### 4.1 Plugin Protocol

```swift
protocol WorkspaceHistoryPlugin: Plugin {
    /// 创建快照
    /// - Parameter label: 可选的快照标签（如 "claude-session-start"）
    /// - Returns: 快照 ID
    func snapshot(label: String?) async throws -> SnapshotID

    /// 列出快照
    /// - Parameters:
    ///   - limit: 最大返回数量
    ///   - filter: 过滤条件
    /// - Returns: 快照信息列表
    func list(limit: Int, filter: SnapshotFilter?) async -> [SnapshotInfo]

    /// 恢复到指定快照
    /// - Parameter id: 快照 ID
    /// - Note: 恢复前会自动创建当前状态的备份快照
    func restore(to id: SnapshotID) async throws

    /// 对比两个快照
    /// - Returns: 文件差异列表
    func diff(from: SnapshotID, to: SnapshotID) async -> [FileDiff]

    /// 获取单个文件的历史版本
    func fileHistory(path: String, limit: Int) async -> [FileVersion]

    /// 标记快照为永久保留
    func pin(snapshot: SnapshotID) async throws

    /// 取消永久保留
    func unpin(snapshot: SnapshotID) async throws
}
```

### 4.2 数据类型

```swift
typealias SnapshotID = String  // 时间戳字符串

struct SnapshotInfo {
    let id: SnapshotID
    let timestamp: Date
    let label: String?
    let source: String          // "scheduled", "claude-guard", "manual"
    let isPinned: Bool
    let stats: SnapshotStats
}

struct SnapshotStats {
    let totalFiles: Int
    let changedFiles: Int
    let storedSize: Int64
}

struct SnapshotFilter {
    var source: String?
    var label: String?
    var since: Date?
    var until: Date?
    var pinnedOnly: Bool = false
}

struct FileDiff {
    let path: String
    let status: FileStatus      // .added, .modified, .deleted
    let oldSize: Int64?
    let newSize: Int64?
}

enum FileStatus {
    case added
    case modified
    case deleted
}

struct FileVersion {
    let snapshotId: SnapshotID
    let timestamp: Date
    let size: Int64
    let label: String?
}
```

## 5. 快照策略

### 5.1 触发时机

| 触发源 | 时机 | Label |
|--------|------|-------|
| 定时器 | 每 5 分钟 | `scheduled` |
| ClaudeGuard | Claude 会话开始 | `claude-session-start` |
| ClaudeGuard | Claude 执行 Edit/Write 前 | `claude-pre-edit` |
| ClaudeGuard | Claude 发生错误 | `claude-error` |
| ShellGuard | 危险命令执行前 | `shell-pre-rm` 等 |
| 用户手动 | 快捷键/命令 | `manual` 或用户指定 |

### 5.2 防抖策略

```swift
// 避免短时间内创建过多快照
let debounceInterval: TimeInterval = 30  // 30 秒内不重复

func shouldSnapshot() -> Bool {
    guard let lastSnapshot = getLastSnapshot() else { return true }
    return Date().timeIntervalSince(lastSnapshot.timestamp) > debounceInterval
}
```

### 5.3 忽略规则

默认忽略：
```
.git/
.svn/
node_modules/
.eterm-history/
*.log
.DS_Store
Thumbs.db
__pycache__/
*.pyc
.venv/
venv/
target/          # Rust
build/           # 通用构建目录
dist/
.cache/
```

支持用户自定义：`~/.eterm/history.ignore` 或项目内 `.etermignore`

## 6. 清理策略

### 6.1 分层保留

```
时间范围          保留粒度        最多保留数
─────────────────────────────────────────
最近 1 小时       每 5 分钟       12 个
1-24 小时        每 30 分钟      46 个
1-7 天           每 2 小时       84 个
7-30 天          每天 1 个       23 个
─────────────────────────────────────────
总计                            ~165 个
```

### 6.2 特殊保留

- **Pinned 快照**：永久保留，不参与清理
- **Labeled 快照**：优先保留（相同时间段内优先保留有 label 的）

### 6.3 清理触发

```swift
// 每次快照后异步清理
func afterSnapshot() {
    Task.detached(priority: .background) {
        await cleanup()
    }
}

// 清理逻辑
func cleanup() async {
    let snapshots = await list(limit: 1000, filter: nil)
    let toDelete = applyRetentionPolicy(snapshots)

    for snapshot in toDelete {
        if !snapshot.isPinned {
            await delete(snapshot)
        }
    }

    // 清理孤立的文件（没有被任何 manifest 引用）
    await pruneOrphanedFiles()
}
```

## 7. 恢复流程

### 7.1 安全恢复

```swift
func restore(to targetId: SnapshotID) async throws {
    // 1. 先备份当前状态
    let backupId = try await snapshot(label: "pre-restore-backup")

    do {
        // 2. 加载目标 manifest
        let manifest = try await loadManifest(targetId)

        // 3. 恢复文件
        for file in manifest.files {
            let content = try await loadFileContent(file, from: targetId)
            let targetPath = projectPath.appendingPathComponent(file.path)

            // 确保目录存在
            try FileManager.default.createDirectory(
                at: targetPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // 写入文件
            try content.write(to: targetPath)

            // 恢复权限
            try FileManager.default.setAttributes(
                [.posixPermissions: file.mode],
                ofItemAtPath: targetPath.path
            )
        }

        // 4. 删除目标快照中不存在的文件
        let currentFiles = Set(scanDirectory().map { $0.path })
        let targetFiles = Set(manifest.files.map { $0.path })
        let toDelete = currentFiles.subtracting(targetFiles)

        for path in toDelete {
            try? FileManager.default.removeItem(
                at: projectPath.appendingPathComponent(path)
            )
        }

    } catch {
        // 恢复失败，提示用户可以恢复到备份
        throw RestoreError.failed(backupId: backupId, underlying: error)
    }
}
```

### 7.2 部分恢复

```swift
// 只恢复特定文件
func restoreFile(path: String, from snapshotId: SnapshotID) async throws {
    // 备份当前文件
    try await backupFile(path)

    let content = try await loadFileContent(path: path, from: snapshotId)
    let targetPath = projectPath.appendingPathComponent(path)
    try content.write(to: targetPath)
}
```

## 8. 性能优化

### 8.1 快速变化检测

```swift
struct FileSignature: Equatable {
    let size: Int64
    let mtime: TimeInterval

    // 不做内容 hash，用 size + mtime 足够判断变化
    static func from(_ url: URL) throws -> FileSignature {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileSignature(
            size: attrs[.size] as! Int64,
            mtime: (attrs[.modificationDate] as! Date).timeIntervalSince1970
        )
    }
}
```

### 8.2 增量扫描（可选优化）

```swift
// 使用 FSEvents 监听变化，减少全量扫描
class FileWatcher {
    private var stream: FSEventStreamRef?
    private var changedPaths: Set<String> = []

    func getChangedPaths() -> Set<String> {
        defer { changedPaths.removeAll() }
        return changedPaths
    }
}

// 快照时只扫描变化的路径
func incrementalSnapshot() async throws -> SnapshotID {
    let changed = fileWatcher.getChangedPaths()

    if changed.isEmpty {
        // 没有变化，跳过
        return lastSnapshotId
    }

    // 只处理变化的文件
    // ...
}
```

### 8.3 压缩策略

```swift
// 文本文件：zlib 压缩（压缩率高）
// 二进制文件：
//   - < 1MB：zlib 压缩
//   - >= 1MB：直接存储（压缩收益低，浪费 CPU）

func compress(_ data: Data, isText: Bool) -> Data {
    if !isText && data.count >= 1_000_000 {
        return data  // 大二进制不压缩
    }
    return try! (data as NSData).compressed(using: .zlib) as Data
}
```

## 9. ClaudeGuard 插件设计

### 9.1 Claude Hooks 集成

```swift
class ClaudeGuardPlugin: Plugin {
    static let id = "claude-guard"
    static let dependencies = ["workspace-history"]

    @Dependency var history: WorkspaceHistoryPlugin

    func activate(context: PluginContext) async throws {
        // 注册 Claude hooks
        context.claudeHooks.on(.sessionStart) { [weak self] session in
            try await self?.history.snapshot(label: "claude-session-start")
        }

        context.claudeHooks.on(.preToolUse) { [weak self] tool in
            guard tool.isFileModifying else { return }
            try await self?.history.snapshot(label: "claude-pre-\(tool.name)")
        }

        context.claudeHooks.on(.error) { [weak self] error in
            try await self?.history.snapshot(label: "claude-error")
        }

        context.claudeHooks.on(.sessionEnd) { [weak self] session in
            // 会话结束时 pin 最后一个快照（可选）
            if let last = await self?.history.list(limit: 1, filter: nil).first {
                try await self?.history.pin(snapshot: last.id)
            }
        }
    }
}
```

### 9.2 识别文件修改的 Tool

```swift
extension Tool {
    var isFileModifying: Bool {
        switch self.name {
        case "Edit", "Write", "NotebookEdit":
            return true
        case "Bash":
            // 检查命令是否可能修改文件
            return bashCommandMayModifyFiles(self.parameters["command"])
        default:
            return false
        }
    }
}

func bashCommandMayModifyFiles(_ command: String?) -> Bool {
    guard let cmd = command else { return false }
    let dangerousPatterns = [
        "rm ", "mv ", "cp ", "touch ", "mkdir ", "rmdir ",
        "chmod ", "chown ", "ln ",
        "> ", ">> ",  // 重定向
        "sed -i", "awk -i",
        "git checkout", "git reset", "git clean"
    ]
    return dangerousPatterns.contains { cmd.contains($0) }
}
```

## 10. UI 集成（未来）

### 10.1 历史面板

```
┌─────────────────────────────────────────────┐
│  Workspace History                      [x] │
├─────────────────────────────────────────────┤
│  ● 14:30:00  claude-session-start    [pin] │
│  ○ 14:25:00  scheduled                     │
│  ○ 14:20:00  scheduled                     │
│  ● 14:15:23  claude-pre-edit         [pin] │
│  ○ 14:10:00  scheduled                     │
│  ...                                        │
├─────────────────────────────────────────────┤
│  [Restore]  [Diff]  [Pin/Unpin]            │
└─────────────────────────────────────────────┘
```

### 10.2 快捷操作

- `Cmd+Shift+H` - 打开历史面板
- `Cmd+Z` (在历史面板) - 恢复到上一个快照
- `Cmd+S` (手动快照) - 创建标记快照

## 11. 实现计划

### Phase 1: MVP
- [ ] 基础存储层（manifest + 文件存储）
- [ ] snapshot() API
- [ ] list() API
- [ ] restore() API
- [ ] 定时快照（5 分钟）
- [ ] 基础清理策略

### Phase 2: ClaudeGuard
- [ ] Claude hooks 集成
- [ ] 识别文件修改操作
- [ ] 自动快照触发

### Phase 3: 优化
- [ ] 增量扫描（FSEvents）
- [ ] diff() API
- [ ] fileHistory() API
- [ ] UI 面板

### Phase 4: 增强（可选）
- [ ] CAS 去重存储
- [ ] ShellGuard 插件
- [ ] 跨设备同步

## 12. 风险与应对

| 风险 | 影响 | 应对措施 |
|------|------|----------|
| 存储空间膨胀 | 磁盘占用过大 | 分层清理 + 压缩 + 大文件阈值 |
| 快照性能影响 | 卡顿 | 异步执行 + 增量扫描 |
| 恢复失败 | 数据丢失 | 恢复前备份 + 事务性写入 |
| FSEvents 丢事件 | 增量不准 | 定期全量校验 |
| 符号链接处理 | 恢复异常 | 只记录链接目标，不跟踪 |
