import SwiftUI
import TesseraKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            HomeView()
                .navigationTitle("Tessera")
                .navigationBarTitleDisplayModeIfAvailable(.inline)
        }
    }
}

// Cross-platform shim: macOS doesn't have navigationBarTitleDisplayMode.
extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeIfAvailable(_ mode: NavigationBarTitleMode) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(mode.uiKitMode)
        #else
        self
        #endif
    }
}

enum NavigationBarTitleMode {
    case inline, large
    #if os(iOS)
    var uiKitMode: NavigationBarItem.TitleDisplayMode {
        switch self { case .inline: return .inline; case .large: return .large }
    }
    #endif
}
