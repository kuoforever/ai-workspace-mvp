import SwiftUI
import UIKit

@main @MainActor struct AIWorkspaceApp: App {
    @StateObject private var workspace = WorkspaceModel()
    var body: some Scene {
        WindowGroup { WorkspaceView(model: workspace).tint(.workspaceTeal) }
    }
}

extension Color {
    static let workspaceTeal = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 139 / 255, green: 216 / 255, blue: 200 / 255, alpha: 1)
            : UIColor(red: 37 / 255, green: 103 / 255, blue: 94 / 255, alpha: 1)
    })
    static let workspaceButton = Color(red: 37 / 255, green: 103 / 255, blue: 94 / 255)
}
