import XCTest
@testable import Luma

final class RTSPInterfaceLeaseTests: XCTestCase {
    func testSameRouteSharesWithoutAnotherNativeWrite() {
        var state = RTSPInterfaceLeaseState()
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(state.acquire(owner: first, address: 1), .configure)
        XCTAssertEqual(state.acquire(owner: second, address: 1), .reuse)
        XCTAssertEqual(state.acquire(owner: first, address: 1), .reuse)
        XCTAssertEqual(state.owners.count, 2)
        state.release(owner: first)
        XCTAssertEqual(state.acquire(owner: UUID(), address: 2), .conflict)
        XCTAssertEqual(state.address, 1)
    }

    func testDifferentRouteOnlyConfiguresAfterEveryInputStops() {
        var state = RTSPInterfaceLeaseState()
        let first = UUID()
        let second = UUID()
        let next = UUID()
        XCTAssertEqual(state.acquire(owner: first, address: 1), .configure)
        XCTAssertEqual(state.acquire(owner: second, address: 1), .reuse)
        state.release(owner: first)
        XCTAssertEqual(state.acquire(owner: next, address: 2), .conflict)
        XCTAssertFalse(state.owners.contains(next))
        state.release(owner: second)
        XCTAssertEqual(state.acquire(owner: next, address: 2), .configure)
        XCTAssertEqual(state.address, 2)
    }

    func testInvalidRoutesAndUnrelatedReleaseCannotBreakLiveLease() {
        var state = RTSPInterfaceLeaseState()
        let owner = UUID()
        XCTAssertEqual(state.acquire(owner: owner, address: 0), .invalid)
        XCTAssertEqual(state.acquire(owner: owner, address: .max), .invalid)
        XCTAssertTrue(state.owners.isEmpty)
        XCTAssertEqual(state.acquire(owner: owner, address: 1), .configure)
        state.release(owner: UUID())
        XCTAssertEqual(state.acquire(owner: UUID(), address: 2), .conflict)
        XCTAssertEqual(state.owners, [owner])
    }
}
