import Foundation

/// Pure lease policy. The SDK queue owns its production instance. A lease
/// covers a pending start as well as a running input; it is released only
/// after synchronous native shutdown. No address is written while leases live.
struct RTSPInterfaceLeaseState {
    enum Acquisition: Equatable {
        case configure, reuse, conflict, invalid
    }

    private(set) var address: UInt32?
    private(set) var owners: Set<UUID> = []

    mutating func acquire(owner: UUID, address requested: UInt32) -> Acquisition {
        guard requested != 0, requested != UInt32.max else { return .invalid }
        if owners.isEmpty {
            address = requested
            owners.insert(owner)
            return .configure
        }
        guard address == requested else { return .conflict }
        owners.insert(owner)
        return .reuse
    }

    mutating func release(owner: UUID) { owners.remove(owner) }
}
