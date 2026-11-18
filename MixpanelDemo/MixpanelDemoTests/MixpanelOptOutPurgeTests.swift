//
//  MixpanelOptOutPurgeTests.swift
//  MixpanelDemoTests
//
//  DLCT fork: covers `optOutTracking()` discarding the unsent queue. Anything tracked before an opt-out
//  must never reach the server, not even after a later `optInTracking()` and a flush.
//

import SQLite3
import XCTest

@testable import Mixpanel

/// A stub Mixpanel server. Records the path and body of every request sent to its host and answers
/// 200 "1", so a flush against it succeeds without touching the network.
private class OptOutStubURLProtocol: URLProtocol {
    struct Recorded {
        let host: String
        let path: String
        let body: String
    }

    /// A primary-host request held in flight: `started` is signalled when it reaches the stub, and the
    /// stub answers with `status` once the test signals `release`.
    struct Hold {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let status: Int
    }

    static let host = "optout-purge-stub.mixpanel.test"
    static let backupHost = "optout-purge-backup.mixpanel.test"
    private static let lock = NSLock()
    private static var recorded: [Recorded] = []
    private static var pendingHold: Hold?

    static func reset() {
        lock.lock()
        recorded = []
        pendingHold = nil
        lock.unlock()
    }

    /// Holds the next request to the primary host in flight until the test releases it.
    static func holdNextPrimaryRequest(status: Int) -> Hold {
        let hold = Hold(status: status)
        lock.lock()
        pendingHold = hold
        lock.unlock()
        return hold
    }

    private static func takeHold() -> Hold? {
        lock.lock()
        defer { lock.unlock() }
        let hold = pendingHold
        pendingHold = nil
        return hold
    }

    static func requests() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func record(_ request: Recorded) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host == host || request.url?.host == backupHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let recorded = Recorded(host: url.host ?? "", path: url.path, body: bodyString())
        guard url.host == OptOutStubURLProtocol.host, let hold = OptOutStubURLProtocol.takeHold() else {
            OptOutStubURLProtocol.record(recorded)
            respond(to: url, status: 200)
            return
        }
        hold.started.signal()
        DispatchQueue.global().async {
            hold.release.wait()
            OptOutStubURLProtocol.record(recorded)
            self.respond(to: url, status: hold.status)
        }
    }

    private func respond(to url: URL, status: Int) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (status == 200 ? "1" : "0").data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a body to the protocol as a stream, not as `httpBody`.
    private func bodyString() -> String {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads the stored opt-out flag at the moment the purge reports that it emptied the store. The purge
/// runs on the instance's `trackingQueue`, and the logger calls its listeners on the calling thread, so
/// what is read here is the state the purge ran in.
private class PurgeOrderProbe: MixpanelLogging {
    private let lock = NSLock()
    private let instanceName: String
    private var flagAtPurge: [Bool?] = []

    init(instanceName: String) {
        self.instanceName = instanceName
    }

    func addMessage(message: MixpanelLogMessage) {
        guard message.text == "Successfully deleted all rows from every table" else { return }
        let flag = MixpanelPersistence.loadOptOutStatusFlag(instanceName: instanceName)
        lock.lock()
        flagAtPurge.append(flag)
        lock.unlock()
    }

    /// The stored flag seen by each purge so far, in order (nil: no flag was stored yet).
    func flagsSeen() -> [Bool?] {
        lock.lock()
        defer { lock.unlock() }
        return flagAtPurge
    }
}

class MixpanelOptOutPurgeTests: MixpanelBaseTests {

    override func setUp() {
        super.setUp()
        OptOutStubURLProtocol.reset()
        URLProtocol.registerClass(OptOutStubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(OptOutStubURLProtocol.self)
        OptOutStubURLProtocol.reset()
        super.tearDown()
    }

    /// An instance that flushes only when the test says so, against the stub server.
    private func makeInstance() -> MixpanelInstance {
        let testMixpanel = Mixpanel.initialize(
            token: randomId(), trackAutomaticEvents: false, flushInterval: 60)
        waitForTrackingQueue(testMixpanel)
        testMixpanel.serverURL = "https://\(OptOutStubURLProtocol.host)"
        return testMixpanel
    }

    private func sentBodies() -> String {
        return OptOutStubURLProtocol.requests().map { $0.body }.joined(separator: "\n")
    }

    private func assertQueuesEmpty(_ token: String, file: StaticString = #filePath, line: UInt = #line) {
        for table in ["events", "people", "groups"] {
            XCTAssertEqual(
                rowCount(token, table: table), 0, "\(table) rows must be gone after an opt-out",
                file: file, line: line)
        }
    }

    // MARK: - Anonymous user

    func testAnonymousEventsTrackedBeforeOptOutAreNeverSentAfterOptIn() {
        let testMixpanel = makeInstance()
        for i in 0..<3 {
            testMixpanel.track(event: "pre-optout-event-\(i)")
        }
        waitForTrackingQueue(testMixpanel)
        XCTAssertEqual(
            eventQueue(token: testMixpanel.apiToken).count, 3,
            "precondition: the events are queued before the opt-out")

        testMixpanel.optOutTracking()
        waitForTrackingQueue(testMixpanel)
        assertQueuesEmpty(testMixpanel.apiToken)

        testMixpanel.optInTracking()
        waitForTrackingQueue(testMixpanel)
        testMixpanel.track(event: "post-optin-event")
        flushAndWaitForTrackingQueue(testMixpanel)

        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-event"), "the flush must reach the stub, or this test proves nothing")
        XCTAssertFalse(
            sent.contains("pre-optout"), "nothing tracked before the opt-out may be sent: \(sent)")
        removeDBfile(testMixpanel.apiToken)
    }

    // MARK: - Identified user

    func testIdentifiedUserQueueAndDeleteAreNeverSentAfterOptInAsAnotherId() {
        let testMixpanel = makeInstance()
        testMixpanel.identify(distinctId: "pre-optout-account")
        testMixpanel.track(event: "pre-optout-identified-event")
        testMixpanel.people.set(property: "pre-optout-people-property", to: "pre-optout-value")
        testMixpanel.getGroup(groupKey: "team", groupID: "pre-optout-team").set(
            property: "pre-optout-group-property", to: "pre-optout-value")
        waitForTrackingQueue(testMixpanel)
        XCTAssertFalse(
            eventQueue(token: testMixpanel.apiToken).isEmpty, "precondition: events are queued")
        XCTAssertFalse(
            peopleQueue(token: testMixpanel.apiToken).isEmpty, "precondition: a people update is queued")
        XCTAssertFalse(
            groupQueue(token: testMixpanel.apiToken).isEmpty, "precondition: a group update is queued")

        testMixpanel.optOutTracking()
        waitForTrackingQueue(testMixpanel)
        assertQueuesEmpty(testMixpanel.apiToken)

        testMixpanel.optInTracking()
        waitForTrackingQueue(testMixpanel)
        testMixpanel.identify(distinctId: "post-optin-account")
        waitForTrackingQueue(testMixpanel)
        testMixpanel.track(event: "post-optin-event")
        flushAndWaitForTrackingQueue(testMixpanel)

        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-event"), "the flush must reach the stub, or this test proves nothing")
        XCTAssertFalse(
            sent.contains("pre-optout"), "no record from before the opt-out may be sent: \(sent)")
        XCTAssertFalse(
            sent.contains("$delete"), "the opt-out's own $delete must not be stamped onto the next id: \(sent)")
        removeDBfile(testMixpanel.apiToken)
    }

    // MARK: - The opt-out itself

    func testOptOutSendsNothing() {
        let testMixpanel = makeInstance()
        testMixpanel.identify(distinctId: "pre-optout-account")
        testMixpanel.track(event: "pre-optout-event")
        testMixpanel.people.set(property: "pre-optout-people-property", to: "pre-optout-value")
        waitForTrackingQueue(testMixpanel)
        XCTAssertFalse(
            eventQueue(token: testMixpanel.apiToken).isEmpty, "precondition: events are queued")

        testMixpanel.optOutTracking()
        waitForTrackingQueue(testMixpanel)
        waitForAsyncTasks()
        waitForTrackingQueue(testMixpanel)

        XCTAssertEqual(
            OptOutStubURLProtocol.requests().count, 0,
            "opting out must send nothing, not even the queued $delete: \(sentBodies())")
        assertQueuesEmpty(testMixpanel.apiToken)
        removeDBfile(testMixpanel.apiToken)
    }

    /// The purge leaves nothing queued, and tracking is refused while opted out, so a row is written
    /// straight to the store to prove the opted-out flush guard still holds on its own.
    func testFlushWhileOptedOutSendsNothing() {
        let testMixpanel = makeInstance()
        testMixpanel.optOutTracking()
        waitForTrackingQueue(testMixpanel)
        testMixpanel.mixpanelPersistence.saveEntity(
            ["event": "written-while-opted-out", "properties": ["token": testMixpanel.apiToken]],
            type: .events)
        XCTAssertEqual(
            eventQueue(token: testMixpanel.apiToken).count, 1, "precondition: a row is queued")

        flushAndWaitForTrackingQueue(testMixpanel)

        XCTAssertEqual(
            OptOutStubURLProtocol.requests().count, 0,
            "a flush while opted out must send nothing: \(sentBodies())")
        XCTAssertEqual(
            eventQueue(token: testMixpanel.apiToken).count, 1, "the row is kept, not sent or deleted")
        removeDBfile(testMixpanel.apiToken)
    }

    // MARK: - Back to back: the opt-out's purge runs before anything queued after it

    /// Holds `trackingQueue` busy so every call made while it is held is queued behind the same
    /// blocker: the interleaving a caller gets when it opts out and in with no wait between them.
    private func holdingTrackingQueue(_ m: MixpanelInstance, _ calls: () -> Void) {
        let gate = DispatchSemaphore(value: 0)
        m.trackingQueue.async { gate.wait() }
        calls()
        gate.signal()
        waitForTrackingQueue(m)
        waitForAsyncTasks()
        waitForTrackingQueue(m)
    }

    func testBackToBackOptOutOptInAnonymousSendsNothingFromBeforeTheOptOut() {
        let m = makeInstance()
        for i in 0..<3 {
            m.track(event: "pre-optout-event-\(i)")
        }
        waitForTrackingQueue(m)
        XCTAssertEqual(rowCount(m.apiToken, table: "events"), 3, "precondition: the events are queued")

        holdingTrackingQueue(m) {
            m.optOutTracking()
            m.flush()
            m.optInTracking()
            m.track(event: "post-optin-event")
        }
        flushAndWaitForTrackingQueue(m)

        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-event"), "an event tracked right after the opt-in must be sent: \(sent)")
        XCTAssertFalse(sent.contains("pre-optout"), "nothing tracked before the opt-out may be sent: \(sent)")
        removeDBfile(m.apiToken)
    }

    func testBackToBackOptOutOptInIdentifiedSendsNothingFromBeforeTheOptOut() {
        let m = makeInstance()
        m.identify(distinctId: "pre-optout-account")
        for i in 0..<3 {
            m.track(event: "pre-optout-event-\(i)")
        }
        m.people.set(property: "pre-optout-people-property", to: "pre-optout-value")
        m.getGroup(groupKey: "team", groupID: "pre-optout-team").set(
            property: "pre-optout-group-property", to: "pre-optout-value")
        waitForTrackingQueue(m)
        XCTAssertFalse(peopleQueue(token: m.apiToken).isEmpty, "precondition: a people update is queued")

        holdingTrackingQueue(m) {
            m.optOutTracking()
            m.optInTracking()
            m.identify(distinctId: "post-optin-account")
            m.track(event: "post-optin-event")
        }
        flushAndWaitForTrackingQueue(m)

        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-event"), "an event tracked right after the opt-in must be sent: \(sent)")
        XCTAssertFalse(sent.contains("pre-optout"), "no record from before the opt-out may be sent: \(sent)")
        XCTAssertFalse(
            sent.contains("$delete"),
            "the opt-out must not leave a $delete to be stamped onto the next id: \(sent)")
        removeDBfile(m.apiToken)
    }

    /// The same calls with no artificial hold, repeated, so the natural interleaving is covered too.
    func testBackToBackOptOutOptInWithoutAHoldNeverSendsFromBeforeTheOptOut() {
        for _ in 0..<10 {
            OptOutStubURLProtocol.reset()
            let m = makeInstance()
            m.identify(distinctId: "pre-optout-account")
            m.track(event: "pre-optout-event")
            m.optOutTracking()
            m.optInTracking()
            m.track(event: "post-optin-event")
            flushAndWaitForTrackingQueue(m)
            let sent = sentBodies()
            XCTAssertTrue(sent.contains("post-optin-event"), "the post-opt-in event must be sent: \(sent)")
            XCTAssertFalse(sent.contains("pre-optout"), "a pre-opt-out event was sent: \(sent)")
            removeDBfile(m.apiToken)
        }
    }

    // MARK: - A purge that cannot be skipped, and an opt-in that cannot send what an opt-out left

    func testPurgeRunsWhenTheConnectionWasLost() {
        let m = makeInstance()
        for i in 0..<3 {
            m.track(event: "pre-optout-event-\(i)")
        }
        m.people.set(property: "pre-optout-people-property", to: "pre-optout-value")
        waitForTrackingQueue(m)
        m.trackingQueue.sync { m.mixpanelPersistence.closeDB() }

        m.optOutTracking()
        waitForTrackingQueue(m)

        assertQueuesEmpty(m.apiToken)
        removeDBfile(m.apiToken)
    }

    func testRowsLeftByAnInterruptedOptOutAreNeverSentAfterOptIn() {
        let token = randomId()
        MixpanelPersistence.saveOptOutStatusFlag(value: true, instanceName: token)
        let leftBehind = MixpanelPersistence(instanceName: token)
        leftBehind.saveEntity(
            ["event": "pre-optout-left-behind", "properties": ["token": token]], type: .events)
        leftBehind.closeDB()
        let m = Mixpanel.initialize(token: token, trackAutomaticEvents: false, flushInterval: 60)
        waitForTrackingQueue(m)
        m.serverURL = "https://\(OptOutStubURLProtocol.host)"
        XCTAssertTrue(m.hasOptedOutTracking(), "precondition: the stored opt-out flag is read at init")

        m.optInTracking()
        waitForTrackingQueue(m)
        m.track(event: "post-optin-event")
        flushAndWaitForTrackingQueue(m)

        XCTAssertTrue(sentBodies().contains("post-optin-event"))
        XCTAssertFalse(sentBodies().contains("pre-optout"), "a row left by an interrupted opt-out was sent")
        removeDBfile(token)
    }

    func testOptInWhenNotOptedOutKeepsTheQueue() {
        let m = makeInstance()
        m.track(event: "queued-while-opted-in")
        waitForTrackingQueue(m)

        m.optInTracking()
        waitForTrackingQueue(m)
        flushAndWaitForTrackingQueue(m)

        XCTAssertTrue(
            sentBodies().contains("queued-while-opted-in"),
            "an opt-in that leaves no opted-out state must not discard the queue: \(sentBodies())")
        removeDBfile(m.apiToken)
    }

    /// The flag is stored before the purge runs, so an opt-out cut short between the two still reads as
    /// opted out on the next start and stops sending what the purge had not yet deleted.
    func testTheOptOutFlagIsStoredBeforeThePurgeRuns() {
        let m = makeInstance()
        m.track(event: "pre-optout-event")
        waitForTrackingQueue(m)
        let probe = PurgeOrderProbe(instanceName: m.name)
        MixpanelLogger.addLogging(probe)
        MixpanelLogger.enableLevel(.info)
        defer { MixpanelLogger.disableLevel(.info) }

        m.optOutTracking()
        waitForTrackingQueue(m)

        XCTAssertEqual(
            probe.flagsSeen().count, 1, "the purge must report once, or this test proves nothing")
        XCTAssertEqual(
            probe.flagsSeen().first ?? nil, true, "the opt-out flag must already be stored when the purge runs")
        removeDBfile(m.apiToken)
    }

    func testPurgeDeletesTheStoreWhenADeleteFails() {
        let m = makeInstance()
        m.people.set(property: "pre-optout-people-property", to: "pre-optout-value")
        waitForTrackingQueue(m)
        XCTAssertEqual(rowCount(m.apiToken, table: "people"), 1, "precondition: a people row is queued")

        // Make the purge's first statement fail: drop the events table behind the SDK's back.
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFilePath(m.apiToken), &other), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(other, "DROP TABLE mixpanel_\(m.apiToken)_events", nil, nil, nil), SQLITE_OK)
        sqlite3_close(other)

        m.optOutTracking()
        waitForTrackingQueue(m)
        assertQueuesEmpty(m.apiToken)  // also proves the three tables exist again

        m.optInTracking()
        waitForTrackingQueue(m)
        m.track(event: "post-optin-event")
        flushAndWaitForTrackingQueue(m)
        XCTAssertTrue(sentBodies().contains("post-optin-event"))
        XCTAssertFalse(sentBodies().contains("pre-optout"))
        removeDBfile(m.apiToken)
    }

    func testOptInStaysOptedOutWhenTheQueueCannotBeDiscarded() throws {
        let m = makeInstance()
        m.optOutTracking()
        waitForTrackingQueue(m)

        // A store that can be neither opened nor deleted: an undeletable directory at its path.
        m.trackingQueue.sync { m.mixpanelPersistence.closeDB() }
        let path = dbFilePath(m.apiToken)
        let manager = FileManager.default
        try manager.removeItem(atPath: path)
        try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
        try manager.setAttributes([.immutable: true], ofItemAtPath: path)
        defer {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: path)
            try? manager.removeItem(atPath: path)
        }

        m.optInTracking()
        waitForTrackingQueue(m)
        XCTAssertTrue(
            m.hasOptedOutTracking(), "an opt-in that can't discard the old queue must not take effect")
        XCTAssertEqual(
            MixpanelPersistence.loadOptOutStatusFlag(instanceName: m.name), true,
            "the stored choice must still read opted out")
        m.track(event: "post-optin-event")
        flushAndWaitForTrackingQueue(m)
        XCTAssertEqual(OptOutStubURLProtocol.requests().count, 0)
    }

    // MARK: - A batch already read when the opt-out runs

    /// An unsent batch a flush read into memory is out of the purge's reach. Nothing tracked before an
    /// opt-out may be sent after it, whether or not the person opted back in straight away.
    func testBatchReadBeforeBackToBackOptOutAndOptInIsNeverSent() {
        let m = makeInstance()
        m.track(event: "pre-optout-inflight")
        waitForTrackingQueue(m)
        // The flush reads its batch on the tracking queue and is then stuck behind this block.
        let networkGate = DispatchSemaphore(value: 0)
        m.networkQueue.async { networkGate.wait() }
        m.flush()
        m.trackingQueue.sync {}

        m.optOutTracking()
        m.optInTracking()
        m.trackingQueue.sync {}
        networkGate.signal()
        waitForTrackingQueue(m)
        waitForTrackingQueue(m)

        XCTAssertFalse(
            sentBodies().contains("pre-optout-inflight"),
            "a batch read before the opt-out must not be sent after it: \(sentBodies().prefix(300))")
        removeDBfile(m.apiToken)
    }

    /// When the purge removes the database file, the new store's ids restart at 1. The result of the batch
    /// read before the opt-out must not delete rows by those ids.
    func testBatchReadBeforeAFileFallbackPurgeNeverDeletesRowsTrackedAfterTheOptIn() {
        let m = makeInstance()
        for name in ["pre-optout-a", "pre-optout-b", "pre-optout-c"] { m.track(event: name) }
        waitForTrackingQueue(m)
        let networkGate = DispatchSemaphore(value: 0)
        m.networkQueue.async { networkGate.wait() }
        m.flush()
        m.trackingQueue.sync {}
        makePurgeFallBackToRemovingTheDatabaseFile(m)

        m.optOutTracking()
        m.optInTracking()
        m.track(event: "post-optin-victim")
        m.trackingQueue.sync {}
        networkGate.signal()
        waitForTrackingQueue(m)
        waitForTrackingQueue(m)
        XCTAssertFalse(
            sentBodies().contains("pre-optout"),
            "nothing tracked before the opt-out may be sent: \(sentBodies().prefix(300))")

        flushAndWaitForTrackingQueue(m)
        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-victim"),
            "an event tracked after the opt-in was deleted: \(sent.prefix(300))")
        XCTAssertTrue(sent.contains("$opt_in"), "the opt-in event was deleted: \(sent.prefix(300))")
        removeDBfile(m.apiToken)
    }

    /// The request was already on the wire when the opt-out ran, and then succeeded. Its success must not
    /// delete rows by id either: here the purge restarted the ids, and a check made only before the send
    /// would not see the opt-out.
    func testBatchSentWhileAFileFallbackPurgeRunsNeverDeletesRowsTrackedAfterTheOptIn() {
        let m = makeInstance()
        for name in ["pre-optout-a", "pre-optout-b", "pre-optout-c"] { m.track(event: name) }
        waitForTrackingQueue(m)
        let hold = OptOutStubURLProtocol.holdNextPrimaryRequest(status: 200)
        m.flush()
        XCTAssertEqual(hold.started.wait(timeout: .now() + 30), .success, "the flush never sent its batch")
        makePurgeFallBackToRemovingTheDatabaseFile(m)

        m.optOutTracking()
        m.optInTracking()
        m.track(event: "post-optin-victim")
        m.trackingQueue.sync {}
        hold.release.signal()
        waitForTrackingQueue(m)
        waitForTrackingQueue(m)

        flushAndWaitForTrackingQueue(m)
        let sent = sentBodies()
        XCTAssertTrue(
            sent.contains("post-optin-victim"),
            "an event tracked after the opt-in was deleted: \(sent.prefix(300))")
        XCTAssertTrue(sent.contains("$opt_in"), "the opt-in event was deleted: \(sent.prefix(300))")
        removeDBfile(m.apiToken)
    }

    /// The first attempt was on the wire when the opt-out ran, and failed. The backup host must not get
    /// the batch, with no opt-in at all.
    func testBackupHostIsNotSentABatchWhoseFirstAttemptFailedAfterAnOptOut() {
        let m = makeInstance()
        m.backupHost = OptOutStubURLProtocol.backupHost
        m.track(event: "pre-optout-backup")
        waitForTrackingQueue(m)
        let hold = OptOutStubURLProtocol.holdNextPrimaryRequest(status: 500)
        m.flush()
        XCTAssertEqual(hold.started.wait(timeout: .now() + 30), .success, "the flush never sent its batch")

        m.optOutTracking()
        m.trackingQueue.sync {}
        XCTAssertTrue(m.hasOptedOutTracking(), "precondition: the opt-out has run")
        hold.release.signal()
        waitForTrackingQueue(m)
        waitForTrackingQueue(m)

        let requests = OptOutStubURLProtocol.requests()
        XCTAssertEqual(
            requests.filter { $0.host == OptOutStubURLProtocol.host }.count, 1,
            "precondition: the primary attempt reached the stub and failed")
        XCTAssertEqual(
            requests.filter { $0.host == OptOutStubURLProtocol.backupHost }.count, 0,
            "the backup host was sent a batch read before the opt-out: \(sentBodies().prefix(300))")
        removeDBfile(m.apiToken)
    }

    /// Drops a table through a second connection, so the purge's single DELETE fails and the purge removes
    /// the database file instead.
    private func makePurgeFallBackToRemovingTheDatabaseFile(_ m: MixpanelInstance) {
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFilePath(m.apiToken), &other), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(other, "DROP TABLE mixpanel_\(m.apiToken)_groups", nil, nil, nil), SQLITE_OK)
        sqlite3_close(other)
    }
}
