extension WorkflowGuard {
    var openingSignals: Set<HarnessCommand> {
        switch self {
        case .predicate(.signal(let command)): [command]
        case .allOf(let parts), .anyOf(let parts):
            parts.reduce(into: []) { $0.formUnion($1.openingSignals) }
        case .always, .predicate, .not: []
        }
    }

    var isImpossible: Bool { self == .anyOf([]) }

    /// Resolve only policy/node observations. Runtime outcomes remain guarded branches.
    func specializing(_ resolve: (WorkflowPredicate) -> Bool?) -> WorkflowGuard {
        switch self {
        case .always: return .always
        case .predicate(let value):
            guard let known = resolve(value) else { return self }
            return known ? .always : .anyOf([])
        case .not(let part):
            let result = part.specializing(resolve)
            if result == .always { return .anyOf([]) }
            if result.isImpossible { return .always }
            return .not(result)
        case .allOf(let parts):
            let results = parts.map { $0.specializing(resolve) }
            if results.contains(where: \.isImpossible) { return .anyOf([]) }
            let remaining = results.filter { $0 != .always }
            return remaining.isEmpty ? .always : .allOf(remaining)
        case .anyOf(let parts):
            let results = parts.map { $0.specializing(resolve) }
            if results.contains(.always) { return .always }
            return .anyOf(results.filter { !$0.isImpossible })
        }
    }
}

extension WorkflowGuard: CustomStringConvertible {
    public var description: String {
        switch self {
        case .always: "Always"
        case .predicate(let predicate): predicate.description
        case .not(let part): "not (\(part.description))"
        case .allOf(let parts): parts.map { "(\($0.description))" }.joined(separator: " and ")
        case .anyOf(let parts):
            parts.isEmpty ? "Never" : parts.map { "(\($0.description))" }.joined(separator: " or ")
        }
    }
}

extension WorkflowPredicate: CustomStringConvertible {
    public var description: String {
        switch self {
        case .signal(let command): command.label
        case .gateOpen(let gate): "\(gate) gate is open"
        case .flagSet(let flag): "\(flag) flag is set"
        case .fact(let fact): fact.rawValue
        }
    }
}
