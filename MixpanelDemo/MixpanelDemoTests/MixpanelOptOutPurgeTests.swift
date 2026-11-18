//
//  MixpanelOptOutPurgeTests.swift
//  MixpanelDemoTests
//
//  DLCT fork: covers `optOutTracking()` discarding the unsent queue. Anything tracked before an opt-out
//  must never reach the server, not even after a later `optInTracking()` and a flush.
//

import XCTest

@testable import Mixpanel

/// A stub Mixpanel server. Records the path and body of every request sent to its host and answers
/// 200 "1", so a flush against it succeeds without touching the network.
private class OptOutStubURLProtocol: URLProtocol {
    struct Recorded {
        let path: String
        let body: String
    }

    static let host = "optout-purge-stub.mixpanel.test"
    private static let lock = NSLock()
    private static var recorded: [Recorded] = []

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
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
        return request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        OptOutStubURLProtocol.record(Recorded(path: url.path, body: bodyString()))
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "1".data(using: .utf8)!)
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
}
