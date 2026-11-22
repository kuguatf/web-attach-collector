import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private let silent: Bool
    private let configPath: String?

    init(arguments: [String]) {
        silent = arguments.contains("--silent")
        if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count {
            configPath = arguments[index + 1]
        } else {
            configPath = nil
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if silent {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                let code = await SilentRunner.run(configPath: configPath)
                exit(code)
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let model = AppModel()
        self.model = model
        let root = RootView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "网页附件采集识别工具"
        window.contentView = hosting
        window.minSize = NSSize(width: 1000, height: 800)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("MainWindow")
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        model.log.info("程序已启动，仅采集已获授权的页面资源")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = model, model.running else { return true }
        let alert = NSAlert()
        alert.messageText = "采集任务正在运行"
        alert.informativeText = "关闭窗口将停止采集并退出，确认继续？"
        alert.addButton(withTitle: "停止并退出")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            model.stopRun()
            return true
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 网页附件采集识别工具", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 网页附件采集识别工具", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 网页附件采集识别工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

enum SilentRunner {
    static func run(configPath: String?) async -> Int32 {
        let log = LogStore()
        defer { log.flush() }
        AppPaths.ensureDirectories()
        let url = configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppPaths.defaultConfigFile
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            log.failed("静默运行失败：配置文件不存在或无法解析（\(url.path)）")
            return 2
        }
        let llmKey = config.smart.apiKey.trimmed.isEmpty ? nil : config.smart.apiKey.trimmed
        if let error = ConfigValidator.firstError(config, llmKey: llmKey) {
            log.failed("静默运行配置错误：\(error)")
            return 2
        }
        guard let lock = RunLock.acquire(url: AppPaths.lockFile) else {
            log.info("已有采集任务正在运行，本次跳过")
            return 0
        }
        defer { lock.release() }

        let stop = StopToken()
        let engine = CollectionEngine(config: config, log: log, forceFull: false, stop: stop, llmKey: llmKey, onProgress: nil)
        let outcome = await engine.run()
        log.info("静默运行结束，退出码 \(outcome.exitCode)")
        return outcome.exitCode
    }
}
