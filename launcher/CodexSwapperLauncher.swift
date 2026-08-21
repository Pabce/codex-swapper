import AppKit
import Foundation

@main
enum CodexSwapperLauncher {
    private static let stockBundleIdentifier = "com.openai.codex"

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        if ProcessInfo.processInfo.environment["CODEX_SWAPPER_SKIP_RUNNING_CHECK"] != "1",
           let running = runningChatGPT() {
            guard confirmQuitAndLaunch() else {
                application.terminate(nil)
                return
            }
            guard running.terminate() else {
                showError("ChatGPT could not be asked to quit. Quit it manually, then try again.")
                application.terminate(nil)
                return
            }
            guard waitForTermination(running, timeout: 15) else {
                showError("ChatGPT did not quit within 15 seconds. Your existing work was left open; quit it manually, then try again.")
                application.terminate(nil)
                return
            }
        }

        guard let launcherURL = Bundle.main.url(forResource: "launch-tier2", withExtension: "sh") else {
            showError("The bundled launch-tier2.sh helper is missing. Re-run the codex-swapper installer.")
            application.terminate(nil)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcherURL.path]
        process.currentDirectoryURL = launcherURL.deletingLastPathComponent()

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            showError("Codex Swapper could not start its launcher: \(error.localizedDescription)")
            application.terminate(nil)
            return
        }

        let standardOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if process.terminationStatus != 0 {
            let details = [standardError, standardOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            showError(details.isEmpty
                ? "The launcher exited with status \(process.terminationStatus)."
                : String(details.prefix(3000)))
        }

        application.terminate(nil)
    }

    private static func runningChatGPT() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == stockBundleIdentifier && !$0.isTerminated
        }
    }

    private static func confirmQuitAndLaunch() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ChatGPT is already running"
        alert.informativeText = "The stock and modded launch modes share one desktop process. Quit the running ChatGPT instance and launch Codex Swapper?"
        alert.addButton(withTitle: "Quit and Launch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func waitForTermination(_ application: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !application.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return application.isTerminated
    }

    private static func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Codex Swapper could not launch"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
