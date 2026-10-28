import Foundation

/// A machine's model as last seen live, for opening instantly before the daemon answers (iOS's saved
/// state; the Mac can use it for its own launch). Plain data: where it's stored, and the pane screen
/// captures that go with it, are the app's business.
///
/// The model includes each pane's agent (state, attention, quiet, message), so a saved Agents list
/// shows what needed the user when the app last saw the machine.
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
        self.state = state
        self.lastSeen = lastSeen
        self.daemonVersion = daemonVersion
        self.instance = instance
        self.featureNames = featureNames
    }

    public var features: Set<Hello.Feature> { Set(featureNames.compactMap(Hello.Feature.init(rawValue:))) }
}
