import Analyzers
import SwiftUI

@main
struct ContextCleanerApp: App {
    @StateObject private var model = AppModel()

    init() {
        BackgroundScanScheduler.register { task in
            Task {
                await AppModel.shared?.runBackgroundScan(task: task)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    AppModel.shared = model
                    model.bootstrap()
                }
        }
    }
}
