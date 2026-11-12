import Foundation
import SafarierCore

struct SubscriptionNodeTableRow: Identifiable {
    let node: SubscriptionNode
    var testState: ManagerModel.ProxyTestState?
    let sourceOrder: Int

    var id: UUID { node.id }

    fileprivate var rank: Int {
        switch testState {
        case .success: return 0
        case .failure: return 2
        default: return 1
        }
    }
}

/// Only measured durations reverse; pending and failed nodes keep their groups and source order.
struct SubscriptionLatencyComparator: SortComparator {
    var order: SortOrder = .forward

    func compare(_ lhs: SubscriptionNodeTableRow, _ rhs: SubscriptionNodeTableRow) -> ComparisonResult {
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank ? .orderedAscending : .orderedDescending
        }
        if case .success(let left) = lhs.testState,
           case .success(let right) = rhs.testState, left.duration != right.duration {
            let ascending = left.duration < right.duration
            return ascending == (order == .forward) ? .orderedAscending : .orderedDescending
        }
        // Stable ties prevent equal or unfinished results from jumping around during a batch.
        if lhs.sourceOrder == rhs.sourceOrder { return .orderedSame }
        return lhs.sourceOrder < rhs.sourceOrder ? .orderedAscending : .orderedDescending
    }
}
