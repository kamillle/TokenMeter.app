import Foundation

enum SessionSortKey: Equatable {
    case input
    case output
    case cost
}

enum SessionSortDirection: Equatable {
    case ascending
    case descending
}

struct SessionSort: Equatable {
    var key: SessionSortKey
    var direction: SessionSortDirection
}

func nextSessionSort(current: SessionSort?, key: SessionSortKey) -> SessionSort? {
    guard current?.key == key else {
        return SessionSort(key: key, direction: .descending)
    }
    return current?.direction == .descending
        ? SessionSort(key: key, direction: .ascending)
        : SessionSort(key: key, direction: .descending)
}

func sortedSessions(_ sessions: [Session], by sort: SessionSort?) -> [Session] {
    guard let sort else { return sessions }
    return sessions.sorted { left, right in
        let comparison: ComparisonResult
        switch sort.key {
        case .input:
            comparison = compare(left.input, right.input)
        case .output:
            comparison = compare(left.output, right.output)
        case .cost:
            switch (left.cost, right.cost) {
            case (.none, .some): return false
            case (.some, .none): return true
            case (.none, .none): comparison = .orderedSame
            case (.some(let leftCost), .some(let rightCost)):
                comparison = compare(leftCost, rightCost)
            }
        }

        if comparison == .orderedSame {
            if left.updated != right.updated { return left.updated > right.updated }
            return left.id < right.id
        }
        return sort.direction == .ascending
            ? comparison == .orderedAscending
            : comparison == .orderedDescending
    }
}

private func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
    if left < right { return .orderedAscending }
    if left > right { return .orderedDescending }
    return .orderedSame
}
