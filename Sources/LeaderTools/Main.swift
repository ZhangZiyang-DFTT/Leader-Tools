import SwiftUI
import AppKit

@main
struct LeaderToolsMain {
    static func main() {
        if CommandLine.arguments.count > 1 {
            do { try LeaderCLI.run(Array(CommandLine.arguments.dropFirst())) }
            catch {
                FileHandle.standardError.write(Data(("ERROR: \(error.localizedDescription)\n").utf8))
                exit(1)
            }
        } else {
            LeaderToolsApp.main()
        }
    }
}

struct LeaderToolsApp: App {
    var body: some Scene {
        WindowGroup("Leader Tools") { LeaderRootView() }
            .defaultSize(width: 1280, height: 860)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .help) {
                    Button("第三方组件与许可证") {
                        if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
    }
}
