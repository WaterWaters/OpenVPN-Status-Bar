import XCTest
@testable import VPNStatusBarCore

final class LaunchTrackerTests: XCTestCase {
    func testBeginIsMonotonic() {
        var tracker = LaunchTracker()
        let first = tracker.begin()
        let second = tracker.begin()
        XCTAssertLessThan(first, second)
        XCTAssertTrue(tracker.isCurrent(second))
        XCTAssertFalse(tracker.isCurrent(first))
    }

    func testInvalidateDropsInFlightGeneration() {
        var tracker = LaunchTracker()
        let generation = tracker.begin()
        XCTAssertTrue(tracker.isCurrent(generation))
        tracker.invalidate()
        XCTAssertFalse(tracker.isCurrent(generation))
    }

    /// 切配置：disconnect（invalidate）→ connect（invalidate）→ 新进程（begin）。
    /// 旧进程的退出事件带的是更早的代次，必须被丢弃。
    func testSwitchProfileSequenceDropsOldExit() {
        var tracker = LaunchTracker()
        let oldProcess = tracker.begin()          // 旧进程启动
        tracker.invalidate()                      // disconnect()
        tracker.invalidate()                      // prepareAndStart()
        let newProcess = tracker.begin()          // 新进程启动

        XCTAssertFalse(tracker.isCurrent(oldProcess), "旧进程退出不能被当成当前隧道断开")
        XCTAssertTrue(tracker.isCurrent(newProcess))
    }

    func testWrapAroundStillComparesEqual() {
        var tracker = LaunchTracker(current: .max)
        let generation = tracker.begin()
        XCTAssertEqual(generation, 0)
        XCTAssertTrue(tracker.isCurrent(generation))
    }
}
