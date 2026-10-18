import XCTest
@testable import ProbeCore

final class LiDARElevatorGroupTests: XCTestCase {
    private func elevator(_ a: (String, String), _ b: (String, String), group: String? = nil) -> LiDARMapLink {
        LiDARMapLink(kind: .elevator, a: .init(map: a.0, node: a.1), b: .init(map: b.0, node: b.1), groupID: group)
    }

    func testLinksSharingADoorBecomeOneElevatorAndSeparateShaftsGetTheirOwnId() {
        let links = LiDARCampusLinks(links: [
            elevator(("f1", "e1"), ("f2", "e2")),
            LiDARMapLink(kind: .walkway, a: .init(map: "f2", node: "x"), b: .init(map: "f2b", node: "y")),
            elevator(("f2", "e2"), ("f3", "e3")),
            elevator(("f1", "w1"), ("f2", "w2")),
        ])
        let (resolved, assigned) = links.resolvingElevatorGroups()
        XCTAssertEqual(assigned, 3)
        XCTAssertEqual(resolved.links[0].group_id, "电梯1")
        XCTAssertEqual(resolved.links[2].group_id, "电梯1")
        XCTAssertEqual(resolved.links[3].group_id, "电梯2")
        XCTAssertNil(resolved.links[1].group_id)
        XCTAssertEqual(resolved.links.resolvingElevatorGroupsCount, 0)
    }

    func testExistingIdsAreKeptAndReusedForTheirShaft() {
        let links = LiDARCampusLinks(links: [
            elevator(("f2", "e2"), ("f3", "e3"), group: "西侧电梯"),
            elevator(("f1", "e1"), ("f2", "e2")),
            elevator(("f1", "k1"), ("f3", "k3"), group: "电梯1"),
            elevator(("f1", "m1"), ("f2", "m2")),
        ])
        let (resolved, assigned) = links.resolvingElevatorGroups()
        XCTAssertEqual(assigned, 2)
        XCTAssertEqual(resolved.links.map(\.group_id), ["西侧电梯", "西侧电梯", "电梯1", "电梯2"])
        XCTAssertEqual(resolved.elevatorGroup(at: .init(map: "f1", node: "e1")), "西侧电梯")
        XCTAssertNil(resolved.elevatorGroup(at: .init(map: "f1", node: "zz")))
        XCTAssertEqual(resolved.nextElevatorGroupName(), "电梯3")
    }

    func testResolutionIsDeterministic() {
        let links = LiDARCampusLinks(links: [elevator(("a", "1"), ("b", "2")), elevator(("c", "3"), ("d", "4"))])
        XCTAssertEqual(links.resolvingElevatorGroups().links, links.resolvingElevatorGroups().links)
    }
}

private extension Array where Element == LiDARMapLink {
    var resolvingElevatorGroupsCount: Int { LiDARCampusLinks(links: self).resolvingElevatorGroups().assigned }
}
