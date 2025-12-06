//
//  CustomProgressView.swift
//  claude-helper
//
//  Created by 💻higuaifan on 2025/8/28.
//

import AppKit

class CustomProgressView: NSView {
    var progress: Double = 0.0 {
        didSet {
            needsDisplay = true
        }
    }
    
    var progressColor: NSColor = .controlAccentColor {
        didSet {
            needsDisplay = true
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // 背景（空的部分）
        NSColor.quaternaryLabelColor.setFill()
        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        backgroundPath.fill()
        
        // 进度条（填充部分）
        if progress > 0 {
            progressColor.setFill()
            let progressWidth = bounds.width * progress
            let progressRect = NSRect(x: 0, y: 0, width: progressWidth, height: bounds.height)
            let progressPath = NSBezierPath(roundedRect: progressRect, xRadius: 2, yRadius: 2)
            progressPath.fill()
        }
    }
    
    func updateProgress(_ newProgress: Double, color: NSColor) {
        progress = newProgress
        progressColor = color
    }
}