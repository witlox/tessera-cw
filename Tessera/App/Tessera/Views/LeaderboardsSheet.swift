#if canImport(GameKit) && canImport(UIKit)
import SwiftUI
import UIKit
import GameKit

/// SwiftUI wrapper for the system Game Center Dashboard opened on the
/// leaderboards tab. Lets the user see both `LeaderboardID.puzzlesSolved`
/// and `LeaderboardID.multiplayerWins` without us having to render score
/// lists ourselves.
struct LeaderboardsSheet: UIViewControllerRepresentable {
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> GKGameCenterViewController {
        let vc = GKGameCenterViewController(state: .leaderboards)
        vc.gameCenterDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: GKGameCenterViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, GKGameCenterControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func gameCenterViewControllerDidFinish(_ gcvc: GKGameCenterViewController) {
            onDismiss()
        }
    }
}
#endif
