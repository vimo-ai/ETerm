# OneLineCommand Plugin

一行命令插件 - 快速执行命令，无需切换到终端窗口

## 功能特性

- **Cmd+Shift+O**: 全局唤起命令输入框
- **窗口居中**: 输入框固定在当前窗口中心，不会乱飘
- **自动聚焦**: 输入框自动获得焦点，可直接输入
- **智能 CWD**: 自动使用当前 Tab 的工作目录
- **后台执行**: 使用轻量级 Process API，不创建终端实例
- **结果预览**: 在输入框下方显示命令输出摘要
- **键盘操作**: 完全键盘驱动（Enter 执行、Esc 关闭）

## 使用示例

```bash
pwd                 # 查看当前目录
ls -la              # 列出文件
git status          # Git 状态
open .              # 打开当前目录
echo "Hello World"  # 简单输出
```

## 实现文件

- `OneLineCommandPlugin.swift` - 插件主文件
- `CommandInputController.swift` - 输入面板控制器
- `CommandInputView.swift` - SwiftUI 输入视图
- `ImmediateExecutor.swift` - 后台命令执行器
