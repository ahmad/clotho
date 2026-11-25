import Foundation

/// A machine's model as last seen live, for opening instantly before the daemon answers (iOS's saved
/// state; the Mac can use it for its own launch). Plain data: where it's stored, and the pane screen
/// captures that go with it, are the app's business.
///
/// The model includes each pane's agent (state, attention, quiet, message), so a saved Agents list
/// shows what needed the user when the app last saw the machine. It never includes a pane's `progress`:
/// a bar from the last session must not show for a machine that isn't connected, so it is dropped
/// when a cache is made and again when one is read.
public struct CachedMachineState: Codable, Equatable, Sendable {
    /// Bumped when the shape changes in a way old caches can't be read as; `restore` ignores others.
    public static let currentFormat = 1
    public var format: Int
    public var state: ModelState
    /// The last moment the app saw the machine live.
    public var lastSeen: Date
    /// The daemon's version and holder instance then. Panes belong to an instance: a different one on
    /// reconnect means new shells, whatever the ids.
    public var daemonVersion: String?
    public var instance: String?
    /// The daemon's announced features then (`Hello.featureNames`), so a saved UI can enable what the
    /// machine supports before it connects.
    public var featureNames: [String]

    public init(state: ModelState, lastSeen: Date, daemonVersion: String? = nil, instance: String? = nil,
                featureNames: [String] = [], format: Int = Self.currentFormat) {
        self.format = format
        self.state = Self.withoutProgress(state)
        self.lastSeen = lastSeen
        self.daemonVersion = daemonVersion
        self.instance = instance
        self.featureNames = featureNames
    }

    enum CodingKeys: String, CodingKey {
        case format, state, lastSeen, daemonVersion, instance, featureNames
    }

    /// As the synthesized one, except that the panes come back without `progress` (a cache written
    /// before this rule, or by hand).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        state = try Self.withoutProgress(c.decode(ModelState.self, forKey: .state))
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        daemonVersion = try c.decodeIfPresent(String.self, forKey: .daemonVersion)
        instance = try c.decodeIfPresent(String.self, forKey: .instance)
        featureNames = try c.decode([String].self, forKey: .featureNames)
    }

    private static func withoutProgress(_ state: ModelState) -> ModelState {
        var state = state
        for index in state.panes.indices { state.panes[index].progress = nil }
        return state
    }

    public var features: Set<Hello.Feature> { Set(featureNames.compactMap(Hello.Feature.init(rawValue:))) }
}
