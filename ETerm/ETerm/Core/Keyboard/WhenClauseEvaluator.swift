//
//  WhenClauseEvaluator.swift
//  ETerm
//
//  应用层 - When 子句求值器

import Foundation

/// When 子句求值器
///
/// 解析和求值 when 条件表达式
///
/// 支持的语法：
/// - 简单条件：`"hasSelection"`, `"!hasSelection"`
/// - 模式匹配：`"mode == normal"`, `"mode == selection"`
/// - 布尔条件：`"imeActive"`, `"!imeActive"`
/// - AND 组合：`"hasSelection && mode == normal"`
/// - OR 组合：`"mode == normal || mode == selection"`
struct WhenClauseEvaluator {

    /// 求值 when 子句
    /// - Parameters:
    ///   - when: when 子句表达式（nil 表示无条件，总是返回 true）
    ///   - context: 求值上下文
    /// - Returns: 条件是否满足
    static func evaluate(_ when: String?, context: WhenClauseContext) -> Bool {
        guard let when = when else { return true }

        let trimmed = when.trimmingCharacters(in: .whitespaces)

        // 支持 OR 组合（优先级低）
        if trimmed.contains("||") {
            let parts = trimmed.components(separatedBy: "||")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.contains { evaluateAndExpression($0, context: context) }
        }

        // 支持 AND 组合
        return evaluateAndExpression(trimmed, context: context)
    }

    /// 求值 AND 表达式
    private static func evaluateAndExpression(_ expression: String, context: WhenClauseContext) -> Bool {
        if expression.contains("&&") {
            let parts = expression.components(separatedBy: "&&")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.allSatisfy { evaluateSingleCondition($0, context: context) }
        }

        return evaluateSingleCondition(expression, context: context)
    }

    /// 求值单一条件
    private static func evaluateSingleCondition(_ condition: String, context: WhenClauseContext) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespaces)

        // 布尔取反
        if trimmed.hasPrefix("!") {
            let innerCondition = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return !evaluateSingleCondition(innerCondition, context: context)
        }

        // 等式判断
        if trimmed.contains("==") {
            let parts = trimmed.components(separatedBy: "==")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return false }

            let key = parts[0]
            let value = parts[1]

            switch key {
            case "mode":
                switch value {
                case "normal": return context.mode == .normal
                case "selection": return context.mode == .selection
                case "copyMode": return context.mode == .copyMode
                default: return false
                }
            default:
                return false
            }
        }

        // 简单布尔条件
        switch trimmed {
        case "hasSelection":
            return context.hasSelection
        case "imeActive":
            return context.imeActive
        default:
            // 未知条件默认返回 true（宽容策略）
            print("⚠️ [WhenClause] 未知条件: \(trimmed)")
            return true
        }
    }
}
