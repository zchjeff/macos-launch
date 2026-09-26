import Foundation
import Testing

@testable import AppBoxCore

/// 收集分发过来的快照，并能等到够数为止。
final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [LibrarySnapshot] = []

    func record(_ snapshot: LibrarySnapshot) {
        lock.withLock { collected.append(snapshot) }
    }

    var snapshots: [LibrarySnapshot] {
        lock.withLock { collected }
    }

    /// 等到收够 `count` 份为止。超时也返回——断言去说哪里不对，别把失败卡成超时错误。
    func wait(forCount count: Int, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, snapshots.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("增量同步：目录变更驱动重扫")
struct LibrarySyncTests {
    /// 装好监听、订阅好收集器的同步器。
    ///
    /// 三个都返回、调用方都要拿着：`LibrarySync` 一旦没人引用，
    /// 事件就传不到订阅者那里了（它对自己的监听闭包只持弱引用）。
    /// 顺手 `defer { sync.stop() }`，每个测试自己收摊。
    private func makeSync(
        fixture: ServiceFixture,
        window: Duration = .milliseconds(50)
    ) -> (sync: LibrarySync, watcher: FakeWatcher, recorder: SnapshotRecorder) {
        let watcher = FakeWatcher()
        let sync = LibrarySync(service: fixture.service, watcher: watcher, window: window)
        let recorder = SnapshotRecorder()
        sync.subscribe { recorder.record($0) }
        sync.start()
        return (sync, watcher, recorder)
    }

    @Test("目录一变就重扫，订阅者拿到新快照")
    func changeDeliversFreshSnapshot() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.alpha", name: "Alpha")
        ])
        let (sync, watcher, recorder) = makeSync(fixture: fixture)
        defer { sync.stop() }

        watcher.fire()
        await recorder.wait(forCount: 1)

        let snapshot = try #require(recorder.snapshots.first)
        #expect(snapshot.visibleApplications.map(\.bundleIdentifier) == ["com.example.alpha"])
        #expect(watcher.isWatching)
    }

    @Test("新装的应用不用重启就能看到，落在「未分类」里")
    func newApplicationAppearsWithoutRestart() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.old", name: "Old")
        ])
        let (sync, watcher, recorder) = makeSync(fixture: fixture)
        defer { sync.stop() }
        watcher.fire()
        await recorder.wait(forCount: 1)

        // 用户这会儿往 /Applications 里拖了一个新应用
        fixture.scanner.setRecords([
            TestRecords.make("com.example.old", name: "Old"),
            TestRecords.make("com.example.new", name: "New"),
        ])
        watcher.fire()
        await recorder.wait(forCount: 2)

        let snapshot = try #require(recorder.snapshots.last)
        let ungrouped = try #require(snapshot.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == ["com.example.new", "com.example.old"])
    }

    @Test("删掉的应用进「失效」列表，从分组里消失，配置一条不丢")
    func deletedApplicationBecomesMissing() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.gone", name: "Gone"),
            TestRecords.make("com.example.keep", name: "Keep"),
        ])
        let group = try fixture.service.createGroup(named: "开发")
        try fixture.service.move(bundleIdentifier: "com.example.gone", toGroup: group.id)
        try fixture.service.setAlias("要删的", for: "com.example.gone")

        let (sync, watcher, recorder) = makeSync(fixture: fixture)
        defer { sync.stop() }
        fixture.scanner.setRecords([TestRecords.make("com.example.keep", name: "Keep")])
        watcher.fire()
        await recorder.wait(forCount: 1)

        let snapshot = try #require(recorder.snapshots.last)
        let record = try #require(snapshot.missing.first)
        #expect(record.bundleIdentifier == "com.example.gone")
        #expect(record.alias == "要删的")
        #expect(record.groupID == group.id)
        // 失效就不该在任何一个分组里露面，隐藏的那些也不算。
        #expect(!snapshot.groups.flatMap(\.applications).contains { $0.bundleIdentifier == "com.example.gone" })
        // 配置保留：卷没挂上、应用暂时看不见，都不该让设置静默蒸发。
        #expect(fixture.service.currentConfig.applications["com.example.gone"]?.groupID == group.id)
    }

    @Test("应用挪了地方不算失效：配置保留，按新位置启动")
    func movedApplicationKeepsItsConfig() async throws {
        let oldPath = "/Applications/App.app"
        let newPath = NSHomeDirectory() + "/Applications/App.app"
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App", path: oldPath)
        ])
        let group = try fixture.service.createGroup(named: "开发")
        try fixture.service.move(bundleIdentifier: "com.example.app", toGroup: group.id)
        try fixture.service.setAlias("挪窝的", for: "com.example.app")

        let (sync, watcher, recorder) = makeSync(fixture: fixture)
        defer { sync.stop() }
        fixture.scanner.setRecords([
            TestRecords.make("com.example.app", name: "App", path: newPath, directory: .userApplications)
        ])
        watcher.fire()
        await recorder.wait(forCount: 1)

        let snapshot = try #require(recorder.snapshots.last)
        #expect(snapshot.missing.isEmpty)
        let entry = try #require(
            snapshot.groups.first { $0.group.id == group.id }?.applications.first
        )
        #expect(entry.path == newPath)
        #expect(entry.alias == "挪窝的")
        #expect(entry.isHidden == false)

        // 位置线索跟着刷新，启动走新路径。
        #expect(fixture.service.currentConfig.applications["com.example.app"]?.lastKnownPath == newPath)
        fixture.service.launch(entry)
        #expect(fixture.launcher.launched.last?.path == newPath)
    }

    @Test("一团变更只扫一次盘，两个订阅者拿到同一份快照")
    func rapidChangesCollapseIntoOneScan() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App")
        ])
        let watcher = FakeWatcher()
        let sync = LibrarySync(service: fixture.service, watcher: watcher, window: .milliseconds(150))
        let first = SnapshotRecorder()
        let second = SnapshotRecorder()
        sync.subscribe { first.record($0) }
        sync.subscribe { second.record($0) }
        sync.start()

        let scansBefore = fixture.scanner.scanCount
        // 一次拖入 20 个应用会报出成百上千个事件，这里只取其中十个。
        for _ in 0..<10 { watcher.fire() }
        await first.wait(forCount: 1)
        try await Task.sleep(for: .milliseconds(300))

        #expect(first.snapshots.count == 1)
        #expect(second.snapshots.count == 1)
        #expect(first.snapshots == second.snapshots)
        // 一次 settle 只该扫一遍：记录位置与发快照共用这一次扫描的结果。
        #expect(fixture.scanner.scanCount - scansBefore == 1)
    }

    @Test("窗口过去之后再来变更，还会再刷一次")
    func changeAfterTheWindowIsDeliveredAgain() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App")
        ])
        let (sync, watcher, recorder) = makeSync(fixture: fixture, window: .milliseconds(80))
        defer { sync.stop() }

        watcher.fire()
        await recorder.wait(forCount: 1)
        try await Task.sleep(for: .milliseconds(200))

        watcher.fire()
        await recorder.wait(forCount: 2)
        try await Task.sleep(for: .milliseconds(200))

        #expect(recorder.snapshots.count == 2)
    }

    @Test("停下来之后不再重扫，连窗口里还没落地的那次也不补")
    func stopCancelsPendingAndFutureChanges() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App")
        ])
        let (sync, watcher, recorder) = makeSync(fixture: fixture, window: .milliseconds(150))

        // 事件已经进来、合并窗口还没到头 —— 这时候停掉
        watcher.fire()
        sync.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.snapshots.isEmpty)

        watcher.fire()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.snapshots.isEmpty)
        #expect(!watcher.isWatching)
    }

    @Test("没人订阅就不扫盘：变更来了也只是把窗口空转过去")
    func noSubscribersMeansNoScan() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App")
        ])
        let watcher = FakeWatcher()
        let sync = LibrarySync(service: fixture.service, watcher: watcher, window: .milliseconds(30))
        sync.start()

        let scansBefore = fixture.scanner.scanCount
        watcher.fire()
        try await Task.sleep(for: .milliseconds(200))

        #expect(fixture.scanner.scanCount == scansBefore)
    }
}
