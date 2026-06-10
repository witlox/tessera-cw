import Foundation

// Service SEAMS only. Concrete StoreKit / GameKit conformances belong in the
// app target and should be built live against Xcode — not stubbed blindly here.
// These protocols let TesseraKit (generator, game logic) stay UI- and
// platform-agnostic and unit-testable.

/// Pro unlock (StoreKit 2, £1.99 one-time). Free tier = English only;
/// Pro = up to 3 of the 6 languages mixed in one grid.
public protocol EntitlementStore {
    var isProUnlocked: Bool { get }
    func purchasePro() async throws
    func restore() async throws
}

/// Language selection gated by entitlement. Centralises the free/Pro rule so it
/// isn't re-implemented per surface.
public struct LanguagePolicy {
    public let entitlements: EntitlementStore
    public init(_ e: EntitlementStore) { entitlements = e }

    public func allowed(_ requested: [Lang]) -> [Lang] {
        if entitlements.isProUnlocked { return Array(requested.prefix(3)) }
        return [.en]                                   // free tier: English only
    }
}

/// Async turn-based match seam (Game Center / GKTurnBasedMatch).
///
/// Fairness contract: a match carries a single puzzle `seed`; both players
/// generate the IDENTICAL board locally via `Generator(seed:)`. Only moves and
/// the shot-clock travel over the wire — never the solution.
public protocol MatchService {
    func startMatch(languages: [Lang]) async throws -> MatchHandle
    func submit(_ move: Move, in match: MatchHandle) async throws
    func endTurn(in match: MatchHandle) async throws
    var inbound: AsyncStream<MatchEvent> { get }
}

public struct MatchHandle: Sendable, Hashable { public let id: String; public let seed: UInt64 }

public struct Move: Sendable, Codable {
    public let cell: CoordWire
    public let letter: Character
    public let atTurnDeadline: Date     // server-trusted shot-clock boundary
}

public enum MatchEvent: Sendable {
    case opponentMove(Move)
    case opponentPassed                 // triggers reveal-on-pass
    case turnTimedOut
    case matchEnded(winner: String?)
}

/// Codable mirror of Coord for the wire (Coord stays a value type internal).
public struct CoordWire: Sendable, Codable, Hashable { public let r: Int; public let c: Int }
