# HistoryKit 设计文档

## 1. 概述

### 1.1 目标

为 ETerm 工作区提供文件系统级别的快照功能，防止：
- 误操作（如 `rm -rf`、错误的 `ln -s`）导致文件丢失
- Claude 编辑代码过程中改崩了无法回滚
- 对话 resume 后丢失上下文，无法恢复到之前的工作状态

### 1.2 设计原则

- **插件化**：核心快照功能作为独立插件，其他插件可依赖调用
- **简单优先**：先实现可用的 MVP，后续再优化
- **不污染项目**：历史数据存储在全局目录，不影响项目结构

---

## 2. 插件拓扑

```
┌─────────────────────────────────────────────────┐
│  HistoryKit（核心快照能力）                       │
│  ├── 定时快照（每 5 分钟）                        │
│  ├── Service API: snapshot / list / restore      │
│  └── 存储管理 + 清理策略                          │
└─────────────────────────────────────────────────┘
        ▲                           ▲
        │ callService               │ subscribes
        │                           │
┌───────┴───────┐           ┌───────┴───────────┐
│ ClaudeGuardKit│           │  其他插件（未来）   │
│ ├── 监听 Claude 事件       │  如 ShellGuardKit │
│ └── 调用快照 API           │                   │
└───────────────┘           └───────────────────┘
```

---

## 3. MVP 范围（先跑起来）

### Phase 1: HistoryKit 核心

- [x] 基础存储层（manifest + 文件存储）
- [x] `snapshot(cwd, label?)` API
- [x] `list(cwd, limit?)` API
- [x] `restore(cwd, snapshotId)` API
- [x] 定时快照（5 分钟，针对 workspace 列表）
- [x] 基础清理策略（保留最近 N 个）
- [x] 按 workspace 维度 30 秒防抖

### Phase 2: ClaudeGuardKit

- [ ] 监听 Claude 事件（sessionStart, promptSubmit 等）
- [ ] 调用 HistoryKit.snapshot()
- [ ] 基于 cwd 判断是否在 workspace 内

### Phase 3: 优化（后续）

- [ ] 非 workspace 目录活跃度检测 + 提示
- [ ] diff() API
- [ ] fileHistory() API
- [ ] UI 面板
- [ ] 增量扫描（FSEvents）

---

## 4. 工作目录来源

### 决策：WorkspaceKit 列表 + 配置

```
主来源：WorkspaceKit 工作区列表
├── 订阅 plugin.com.eterm.workspace.didUpdate 事件
└── 获取用户认可的项目目录列表

补充来源：插件设置
├── 手动添加额外目录
└── 排除规则（如 node_modules）

活跃 Tab CWD：
└── 仅用于 API 调用时的默认值，不作为快照来源
```

### 理由

- WorkspaceKit 是"用户认可的项目集合"，一致性最好
- 活跃 Tab 变化太频繁，会造成快照噪声与遗漏
- 配置覆盖边缘需求（临时项目、monorepo 子目录）

---

## 5. 快照触发时机

### 触发源

| 触发源 | 时机 | Label |
|--------|------|-------|
| 定时器 | 每 5 分钟，遍历所有 workspace | `scheduled` |
| ClaudeGuardKit | Claude 会话开始 | `claude-session-start` |
| ClaudeGuardKit | Claude 执行 Edit/Write 前 | `claude-pre-edit` |
| ClaudeGuardKit | Claude 发生错误 | `claude-error` |
| 用户手动 | 快捷键/命令 | `manual` 或用户指定 |

### 防抖策略

```swift
// 按 workspace 维度防抖，30 秒内不重复
var lastSnapshotTime: [String: Date] = [:]  // cwd -> lastTime

func shouldSnapshot(cwd: String) -> Bool {
    guard let last = lastSnapshotTime[cwd] else { return true }
    return Date().timeIntervalSince(last) > 30
}
```

### 多项目策略

- 定时快照：遍历所有 workspace，每个独立快照
- API 调用：只快照指定的 cwd

---

## 6. 技术栈选型

### 6.1 总览

| 组件 | 选型 | 理由 |
|------|------|------|
| **索引存储** | SQLite（系统自带） | macOS 自带，查询方便，清理容易 |
| **文件存储** | 纯文件 + zlib 压缩 | 简单，不把大数据塞 SQLite |
| **变化检测** | mtime + size | 不做内容 hash，性能优先 |
| **diff 算法** | Swift 标准库 `difference(from:)` | 文本 diff 够用 |
| **二进制处理** | 直接存储（不做 diff） | bsdiff 收益不稳定，复杂度高 |
| **压缩** | zlib（系统自带） | `Data.compressed(using: .zlib)` |
| **并发** | Swift Concurrency (async/await) | 现代 Swift 标准 |

### 6.2 依赖

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nicklockwood/GRDB.swift.git", from: "6.0.0")  // SQLite 封装（可选，也可用原生 SQLite3）
]

// 或者使用系统自带的 SQLite3
import SQLite3
```

**注意**：MVP 阶段可以先不用 GRDB，直接用 SQLite3 C API 或者纯 JSON 文件索引。

### 6.3 核心类型定义

```swift
import Foundation

// MARK: - Snapshot 数据模型

struct Snapshot: Codable, Identifiable {
    let id: String              // 时间戳字符串，如 "1703145600000"
    let timestamp: Date
    let label: String?          // "scheduled", "claude-session-start", etc.
    let source: String?         // "history-kit", "claude-guard", etc.
    let fileCount: Int
    let changedCount: Int
    let storedSize: Int64
}

struct FileEntry: Codable {
    let path: String            // 相对路径，如 "src/main.swift"
    let size: Int64
    let mtime: TimeInterval     // Unix timestamp
    let mode: UInt16            // 文件权限
    let stored: Bool            // true=本快照存储，false=引用
    let reference: String?      // 引用的快照 ID（stored=false 时）
}

struct SnapshotManifest: Codable {
    let id: String
    let timestamp: Date
    let label: String?
    let source: String?
    let files: [FileEntry]
    let stats: SnapshotStats
}

struct SnapshotStats: Codable {
    let totalFiles: Int
    let changedFiles: Int
    let storedSize: Int64
}

// MARK: - 项目元信息

struct ProjectMeta: Codable {
    let projectPath: String
    let projectHash: String
    let createdAt: Date
    var lastSnapshotAt: Date?
    var totalSnapshots: Int
}
```

### 6.4 SQLite Schema

```sql
-- 项目表（每个工作目录一个记录）
CREATE TABLE IF NOT EXISTS projects (
    hash TEXT PRIMARY KEY,          -- sha256(path).prefix(16)
    path TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_snapshot_at INTEGER,
    total_snapshots INTEGER DEFAULT 0
);

-- 快照表
CREATE TABLE IF NOT EXISTS snapshots (
    id TEXT PRIMARY KEY,            -- 时间戳字符串
    project_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    label TEXT,
    source TEXT,
    file_count INTEGER,
    changed_count INTEGER,
    stored_size INTEGER,
    FOREIGN KEY (project_hash) REFERENCES projects(hash)
);

-- 文件表（用于快速查询文件历史）
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_id TEXT NOT NULL,
    path TEXT NOT NULL,
    size INTEGER,
    mtime INTEGER,
    mode INTEGER,
    stored INTEGER,                 -- 1=有存储, 0=引用
    reference_id TEXT,              -- 引用的快照 ID
    FOREIGN KEY (snapshot_id) REFERENCES snapshots(id)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_snapshots_project ON snapshots(project_hash);
CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_files_snapshot ON files(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
```

### 6.5 存储层接口

```swift
/// 存储层协议
protocol SnapshotStore {
    /// 创建快照
    func createSnapshot(
        projectPath: String,
        label: String?,
        source: String?
    ) async throws -> Snapshot

    /// 列出快照
    func listSnapshots(
        projectPath: String,
        limit: Int
    ) async -> [Snapshot]

    /// 获取快照详情
    func getSnapshot(
        projectPath: String,
        snapshotId: String
    ) async -> SnapshotManifest?

    /// 恢复快照
    func restoreSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws

    /// 删除快照
    func deleteSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws

    /// 清理旧快照
    func cleanup(
        projectPath: String,
        keepCount: Int
    ) async throws
}
```

---

## 7. 存储设计

### 7.1 存储路径

```
~/.eterm/
└── history/
    ├── index.db                  # SQLite 数据库（所有项目共用）
    └── projects/
        └── <project-hash>/       # sha256(project-path).prefix(16)
            ├── meta.json         # 项目元信息（冗余，便于调试）
            └── snapshots/
                ├── <timestamp>/  # 毫秒时间戳
                │   ├── manifest.json
                │   └── files/
                │       ├── src%2Fmain.swift.gz
                │       └── ...
                └── <timestamp>/
                    └── ...
```

### 7.2 manifest.json

```json
{
    "id": "1703145600000",
    "timestamp": 1703145600000,
    "label": "claude-session-start",
    "source": "claude-guard",
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

### 7.3 忽略规则

默认忽略：
```
.git/
node_modules/
.eterm-history/
*.log
.DS_Store
__pycache__/
target/
build/
dist/
.cache/
```

---

## 8. Service API

### 8.1 HistoryKit 注册的服务

```swift
// 在 activate 时注册
host.registerService(name: "snapshot") { params in
    let cwd = params["cwd"] as? String ?? self.getActiveCwd()
    let label = params["label"] as? String

    guard self.shouldSnapshot(cwd: cwd) else {
        return ["skipped": true, "reason": "debounced"]
    }

    let snapshotId = await self.createSnapshot(cwd: cwd, label: label)
    return ["snapshotId": snapshotId]
}

host.registerService(name: "list") { params in
    let cwd = params["cwd"] as? String ?? self.getActiveCwd()
    let limit = params["limit"] as? Int ?? 20

    let snapshots = self.listSnapshots(cwd: cwd, limit: limit)
    return ["snapshots": snapshots.map { $0.toDictionary() }]
}

host.registerService(name: "restore") { params in
    guard let cwd = params["cwd"] as? String,
          let snapshotId = params["snapshotId"] as? String else {
        return ["error": "missing parameters"]
    }

    try await self.restore(cwd: cwd, to: snapshotId)
    return ["success": true]
}
```

### 8.2 ClaudeGuardKit 调用示例

```swift
func handleClaudeEvent(_ eventName: String, payload: [String: Any]) {
    guard let cwd = payload["cwd"] as? String else { return }

    // 检查是否在 workspace 内
    guard isInWorkspace(cwd) else { return }

    let label: String
    switch eventName {
    case "claude.sessionStart":
        label = "claude-session-start"
    case "claude.promptSubmit":
        label = "claude-pre-edit"
    case "claude.error":
        label = "claude-error"
    default:
        return
    }

    host?.callService(
        pluginId: "com.eterm.history",
        name: "snapshot",
        params: ["cwd": cwd, "label": label]
    )
}
```

---

## 9. 清理策略

### MVP 简化版

```swift
// 保留最近 50 个快照，超过就删除最旧的
func cleanup(cwd: String) {
    let snapshots = listSnapshots(cwd: cwd, limit: 100)
    if snapshots.count > 50 {
        let toDelete = snapshots.suffix(from: 50)
        for snapshot in toDelete {
            deleteSnapshot(snapshot)
        }
    }
}
```

### 后续优化：分层保留

```
时间范围          保留粒度        最多保留数
─────────────────────────────────────────
最近 1 小时       每 5 分钟       12 个
1-24 小时        每 30 分钟      46 个
1-7 天           每 2 小时       84 个
7-30 天          每天 1 个       23 个
```

---

## 10. 非 Workspace 目录提示（Phase 3）

### 场景

用户在 `/tmp/some-project` 下多次使用 Claude，但该目录不在 workspace 列表。

### 方案

```swift
// 在 ClaudeGuardKit 中
var cwdActivityCount: [String: Int] = [:]

func handleClaudeEvent(cwd: String) {
    if !isInWorkspace(cwd) {
        cwdActivityCount[cwd, default: 0] += 1

        // 达到阈值（3 次操作）
        if cwdActivityCount[cwd] == 3 {
            showNotification(
                title: "历史快照未启用",
                message: "检测到您在 \(cwd) 下进行了多次操作，是否加入工作区以启用历史快照保护？",
                actions: ["加入工作区", "忽略"]
            )
        }
    }
}
```

---

## 11. Manifest 配置

### HistoryKit

```json
{
    "id": "com.eterm.history",
    "name": "历史快照",
    "version": "0.0.1-beta.1",
    "minHostVersion": "0.0.1-beta.1",
    "sdkVersion": "0.0.1-beta.1",
    "runMode": "main",
    "dependencies": [],
    "capabilities": [
        "service.register",
        "ui.sidebar"
    ],
    "principalClass": "HistoryKit.HistoryPlugin",
    "sidebarTabs": [
        {
            "id": "history-panel",
            "title": "历史",
            "icon": "clock.arrow.circlepath",
            "viewClass": "HistoryPanelView"
        }
    ],
    "subscribes": [
        "plugin.com.eterm.workspace.didUpdate"
    ],
    "emits": []
}
```

### ClaudeGuardKit

```json
{
    "id": "com.eterm.claude-guard",
    "name": "Claude 保护",
    "version": "0.0.1-beta.1",
    "minHostVersion": "0.0.1-beta.1",
    "sdkVersion": "0.0.1-beta.1",
    "runMode": "main",
    "dependencies": [
        { "id": "com.eterm.history", "minVersion": "0.0.1-beta.1" }
    ],
    "capabilities": [
        "service.call"
    ],
    "principalClass": "ClaudeGuardKit.ClaudeGuardPlugin",
    "sidebarTabs": [],
    "subscribes": [
        "claude.sessionStart",
        "claude.promptSubmit",
        "claude.waitingInput",
        "claude.responseComplete",
        "claude.sessionEnd"
    ],
    "emits": []
}
```

---

## 12. 实现计划

### MVP（先跑起来）

1. **HistoryKit 骨架**
   - Package.swift + manifest.json
   - HistoryPlugin 基础结构
   - 存储层（SnapshotStore）

2. **核心功能**
   - snapshot() 实现
   - list() 实现
   - 定时快照（Timer）
   - 简单清理（保留 50 个）

3. **ClaudeGuardKit**
   - 监听 Claude 事件
   - 调用 HistoryKit.snapshot()

### 后续优化

- restore() 实现
- diff() 实现
- UI 面板
- 分层清理策略
- 非 workspace 提示
- 增量扫描

---

## 13. 核心流程

### 13.1 快照创建流程

```swift
func createSnapshot(projectPath: String, label: String?, source: String?) async throws -> Snapshot {
    let projectHash = sha256(projectPath).prefix(16)
    let snapshotId = String(Int(Date().timeIntervalSince1970 * 1000))

    // 1. 获取上一个快照的 manifest（用于增量比较）
    let lastManifest = await getLastManifest(projectHash: projectHash)
    let lastFiles = lastManifest?.files.reduce(into: [:]) { $0[$1.path] = $1 } ?? [:]

    // 2. 扫描目录
    let currentFiles = try scanDirectory(projectPath)

    // 3. 比较差异，决定哪些文件需要存储
    var fileEntries: [FileEntry] = []
    var changedCount = 0
    var storedSize: Int64 = 0

    for file in currentFiles {
        let signature = FileSignature(size: file.size, mtime: file.mtime)

        if let last = lastFiles[file.path],
           last.size == file.size && last.mtime == file.mtime {
            // 未变化，引用上一个快照
            fileEntries.append(FileEntry(
                path: file.path,
                size: file.size,
                mtime: file.mtime,
                mode: file.mode,
                stored: false,
                reference: last.stored ? lastManifest!.id : last.reference
            ))
        } else {
            // 变化了，需要存储
            changedCount += 1
            let compressedSize = try await storeFile(
                projectHash: projectHash,
                snapshotId: snapshotId,
                file: file
            )
            storedSize += compressedSize

            fileEntries.append(FileEntry(
                path: file.path,
                size: file.size,
                mtime: file.mtime,
                mode: file.mode,
                stored: true,
                reference: nil
            ))
        }
    }

    // 4. 保存 manifest
    let manifest = SnapshotManifest(
        id: snapshotId,
        timestamp: Date(),
        label: label,
        source: source,
        files: fileEntries,
        stats: SnapshotStats(
            totalFiles: fileEntries.count,
            changedFiles: changedCount,
            storedSize: storedSize
        )
    )
    try await saveManifest(projectHash: projectHash, manifest: manifest)

    // 5. 更新 SQLite 索引
    try await updateIndex(projectHash: projectHash, manifest: manifest)

    // 6. 触发清理（异步）
    Task.detached(priority: .background) {
        try? await self.cleanup(projectPath: projectPath, keepCount: 50)
    }

    return Snapshot(from: manifest)
}
```

### 13.2 目录扫描

```swift
struct ScannedFile {
    let path: String        // 相对路径
    let absolutePath: URL
    let size: Int64
    let mtime: TimeInterval
    let mode: UInt16
    let isDirectory: Bool
}

func scanDirectory(_ projectPath: String) throws -> [ScannedFile] {
    let baseURL = URL(fileURLWithPath: projectPath)
    let fm = FileManager.default

    // 加载忽略规则
    let ignorePatterns = loadIgnorePatterns(projectPath)

    var results: [ScannedFile] = []

    let enumerator = fm.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .posixPermissionsKey],
        options: [.skipsHiddenFiles]  // 可选：跳过隐藏文件
    )

    while let url = enumerator?.nextObject() as? URL {
        let relativePath = url.path.replacingOccurrences(of: baseURL.path + "/", with: "")

        // 检查忽略规则
        if shouldIgnore(relativePath, patterns: ignorePatterns) {
            if url.hasDirectoryPath {
                enumerator?.skipDescendants()
            }
            continue
        }

        // 只处理普通文件
        guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .posixPermissionsKey]),
              resourceValues.isRegularFile == true else {
            continue
        }

        // 跳过大文件（> 10MB）
        let size = Int64(resourceValues.fileSize ?? 0)
        if size > 10 * 1024 * 1024 {
            continue
        }

        results.append(ScannedFile(
            path: relativePath,
            absolutePath: url,
            size: size,
            mtime: resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0,
            mode: UInt16(resourceValues.posixPermissions ?? 0o644),
            isDirectory: false
        ))
    }

    return results
}
```

### 13.3 文件存储

```swift
func storeFile(projectHash: String, snapshotId: String, file: ScannedFile) async throws -> Int64 {
    // 读取文件内容
    let data = try Data(contentsOf: file.absolutePath)

    // 压缩
    let compressed = try (data as NSData).compressed(using: .zlib) as Data

    // 构建存储路径
    let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.path
    let storePath = historyRoot
        .appendingPathComponent("projects")
        .appendingPathComponent(projectHash)
        .appendingPathComponent("snapshots")
        .appendingPathComponent(snapshotId)
        .appendingPathComponent("files")
        .appendingPathComponent(encodedPath + ".gz")

    // 确保目录存在
    try FileManager.default.createDirectory(
        at: storePath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // 写入文件
    try compressed.write(to: storePath)

    return Int64(compressed.count)
}
```

### 13.4 恢复流程

```swift
func restoreSnapshot(projectPath: String, snapshotId: String) async throws {
    let projectHash = sha256(projectPath).prefix(16)

    // 1. 先创建一个备份快照
    _ = try await createSnapshot(
        projectPath: projectPath,
        label: "pre-restore-backup",
        source: "history-kit"
    )

    // 2. 加载目标 manifest
    guard let manifest = await getManifest(projectHash: projectHash, snapshotId: snapshotId) else {
        throw HistoryError.snapshotNotFound
    }

    // 3. 恢复每个文件
    for file in manifest.files {
        let content = try await loadFileContent(
            projectHash: projectHash,
            file: file
        )

        let targetPath = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(file.path)

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

    // 4. 删除目标快照中不存在的文件（可选）
    let manifestPaths = Set(manifest.files.map { $0.path })
    let currentFiles = try scanDirectory(projectPath)

    for current in currentFiles {
        if !manifestPaths.contains(current.path) {
            try? FileManager.default.removeItem(at: current.absolutePath)
        }
    }
}

func loadFileContent(projectHash: String, file: FileEntry) async throws -> Data {
    let snapshotId = file.stored ? file.reference ?? "" : file.reference!

    let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.path
    let storePath = historyRoot
        .appendingPathComponent("projects")
        .appendingPathComponent(projectHash)
        .appendingPathComponent("snapshots")
        .appendingPathComponent(snapshotId)
        .appendingPathComponent("files")
        .appendingPathComponent(encodedPath + ".gz")

    let compressed = try Data(contentsOf: storePath)
    let decompressed = try (compressed as NSData).decompressed(using: .zlib) as Data

    return decompressed
}
```

### 13.5 Project Hash 计算

```swift
import CryptoKit

func projectHash(for path: String) -> String {
    let normalized = (path as NSString).standardizingPath
    let data = normalized.data(using: .utf8)!
    let hash = SHA256.hash(data: data)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
}
```

---

## 14. 文件目录结构

### 14.1 插件源码结构

```
Plugins/HistoryKit/
├── Package.swift
├── Resources/
│   └── manifest.json
└── Sources/HistoryKit/
    ├── HistoryPlugin.swift           # 插件入口
    ├── HistoryService.swift          # Service API 实现
    ├── Store/
    │   ├── SnapshotStore.swift       # 存储层协议
    │   ├── FileSnapshotStore.swift   # 文件存储实现
    │   └── SQLiteIndex.swift         # SQLite 索引
    ├── Scanner/
    │   ├── DirectoryScanner.swift    # 目录扫描
    │   └── IgnoreRules.swift         # 忽略规则
    ├── Models/
    │   ├── Snapshot.swift            # 数据模型
    │   ├── FileEntry.swift
    │   └── ProjectMeta.swift
    └── Views/
        └── HistoryPanelView.swift    # 侧边栏视图（Phase 3）
```

### 14.2 ClaudeGuardKit 结构

```
Plugins/ClaudeGuardKit/
├── Package.swift
├── Resources/
│   └── manifest.json
└── Sources/ClaudeGuardKit/
    ├── ClaudeGuardPlugin.swift       # 插件入口
    ├── EventHandler.swift            # Claude 事件处理
    └── WorkspaceChecker.swift        # Workspace 检查
```

---

## 15. 风险与应对

| 风险 | 影响 | 应对措施 |
|------|------|----------|
| 存储空间膨胀 | 磁盘占用过大 | 清理策略 + 压缩 + 大文件跳过 |
| 快照性能影响 | 卡顿 | 异步执行 + 防抖 |
| 恢复失败 | 数据丢失 | 恢复前自动备份 |
| 大文件处理 | 内存/时间 | 跳过 > 10MB 文件 |
| 引用链断裂 | 无法恢复 | 清理时检查引用完整性 |
| 并发写入 | 数据损坏 | 文件锁 / Actor 隔离 |
