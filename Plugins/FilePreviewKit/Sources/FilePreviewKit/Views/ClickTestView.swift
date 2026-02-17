import SwiftUI
import AppKit

struct ClickTestView: View {
    @State private var count = 0
    @State private var log: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("点击测试")
                .font(.title2)

            Text("计数: \(count)")
                .font(.largeTitle)

            // 1. SwiftUI Button
            Button("SwiftUI Button") {
                count += 1
                log.append("[\(log.count)] Button clicked")
                NSLog("[ClickTest] Button clicked, count=\(count)")
            }
            .buttonStyle(.borderedProminent)

            // 2. Plain Button
            Button(action: {
                count += 10
                log.append("[\(log.count)] Plain Button clicked")
                NSLog("[ClickTest] Plain Button clicked, count=\(count)")
            }) {
                Text("Plain Button (+10)")
                    .padding(8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // 3. onTapGesture
            Text("onTapGesture (+100)")
                .padding(8)
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(6)
                .onTapGesture {
                    count += 100
                    log.append("[\(log.count)] onTapGesture")
                    NSLog("[ClickTest] onTapGesture, count=\(count)")
                }

            // 4. NSViewRepresentable Button
            AppKitButtonView(title: "AppKit NSButton (+1000)") {
                count += 1000
                log.append("[\(log.count)] NSButton clicked")
                NSLog("[ClickTest] NSButton clicked, count=\(count)")
            }
            .frame(height: 30)

            Divider()

            // Log
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log, id: \.self) { entry in
                        Text(entry).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// NSButton 包装，测试 AppKit 原生按钮是否能收到事件
struct AppKitButtonView: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}
