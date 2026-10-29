import Foundation

/// What the harness needs to know about items owned by other systems or teams.
public protocol ExternalDependencySource: Sendable {
    func deliveredKeys() async -> Set<String>
}

