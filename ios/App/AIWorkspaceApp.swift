import SwiftUI

@main @MainActor struct AIWorkspaceApp: App {
    @StateObject private var workspace = WorkspaceModel()
    var body: some Scene {
        WindowGroup { WorkspaceView(model: workspace).tint(.workspaceTeal) }
    }
}

extension Color {
    static let workspaceTeal = Color(red: 37 / 255, green: 103 / 255, blue: 94 / 255)
}
