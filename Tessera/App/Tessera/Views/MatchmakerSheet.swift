#if canImport(GameKit) && canImport(UIKit)
import SwiftUI
import UIKit
import GameKit

/// SwiftUI wrapper around `GKTurnBasedMatchmakerViewController` — the
/// standard Game Center UI with both Auto-Match and friend-invite paths.
/// When the user picks players, GameKit creates the match and the
/// `GameKitMatchService` player listener fires `newMatches` for it;
/// `AppModel` then attaches and routes us into `MatchPlayView`.
struct MatchmakerSheet: UIViewControllerRepresentable {
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> GKTurnBasedMatchmakerViewController {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.defaultNumberOfPlayers = 2
        request.inviteMessage = "Play Tessera with me"
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = context.coordinator
        // Match selection is also possible — let the user resume any open match.
        vc.showExistingMatches = true
        return vc
    }

    func updateUIViewController(_ vc: GKTurnBasedMatchmakerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel, onError: onError)
    }

    final class Coordinator: NSObject, GKTurnBasedMatchmakerViewControllerDelegate {
        let onCancel: () -> Void
        let onError: (Error) -> Void

        init(onCancel: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onCancel = onCancel
            self.onError = onError
        }

        // User tapped Cancel.
        func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
            onCancel()
        }

        // GameKit threw during matchmaking.
        func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController,
                                               didFailWithError error: Error) {
            onError(error)
        }

        // Note: there's deliberately no `didFind` callback. When the user
        // picks/creates a match, GameKit dismisses the VC itself and
        // delivers the match via `GKLocalPlayerListener
        // .player(_:receivedTurnEventFor:didBecomeActive:)` with
        // didBecomeActive = true. That's the contract the service relies on.
    }
}
#endif
