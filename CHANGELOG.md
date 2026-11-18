# DayLight Creative Technologies fork (dlct_mixpanel_swift)

This repository is a fork of [mixpanel/mixpanel-swift](https://github.com/mixpanel/mixpanel-swift) at 7.1.0. The podspec
version stays `7.1.0` on purpose: `mixpanel_flutter` 3.2.0 pins `Mixpanel-swift` to exactly `7.1.0`, so a fork that kept
another version would not resolve. Fork releases are named in this file and identified by commit SHA, not by tag.

## 7.1.0-dlct.1 (2026-11-18)

### Fixes

- `optOutTracking()` now discards every unsent row of every persistence type (events, people and group updates, identified
  or not). Before, it only stopped sending: a later `optInTracking()` and flush sent everything that had been tracked before
  the opt-out. For an identified user the opt-out also queued a `$delete` and a `$set` (`clearCharges`) people update as
  *unidentified* rows, and the next `identify()` stamped them onto the new identity and sent them.
  - A block queued on `trackingQueue` after the inserts the opt-out schedules (`deleteUser()`, `clearCharges()`) deletes all
    rows through `MPDB.deleteRows(_:isDeleteAll:)` (new `MixpanelPersistence.removeAllEntities()`). Nothing is sent at the
    opt-out: the `flush()` the opt-out schedules for an identified user still stops at the opted-out guard.
  - The existing opt-out tests that asserted the old behaviour (queued rows survive an opt-out) now assert the purge.
  - New tests: `MixpanelOptOutPurgeTests` (`MixpanelDemo/MixpanelDemoTests`), run by `.github/workflows/build.yml`.

### Upstream issue (text only, not filed)

Title: `optOutTracking()` does not purge queued data, so a later `optInTracking()` sends it

Body:

> **Version:** 7.1.0
>
> The 6.8.0 release notes say: "`reset()` no longer deletes queued events, group updates or identified people updates. ...
> Use `optOutTracking()` if you need to purge queued data."
>
> `optOutTracking()` does not purge queued data. In 7.1.0 (`MixpanelInstance.swift`, `optOutTracking()`) it only sets the
> opted-out flag, which makes `track()`, `people` calls and `flush()` return early. Rows already in the SQLite queue stay
> there, so after `optInTracking()` the next flush sends everything that was tracked before the opt-out.
>
> **Repro (anonymous):**
> 1. `track("a")`, `track("b")`.
> 2. `optOutTracking()`.
> 3. `optInTracking()`, then `flush()`.
> 4. The server receives `a` and `b`.
>
> **Repro (identified):**
> 1. `identify("user-1")`, `track("a")`, `people.set(...)`.
> 2. `optOutTracking()`. This schedules `people.deleteUser()` and `people.clearCharges()`. By the time they run, the same
>    block has cleared `people.distinctId` and set the opted-out flag, so the `$delete` and the `$set` are saved as
>    unidentified people rows and the scheduled `flush()` stops at the guard.
> 3. `optInTracking()`, `identify("user-2")`, `flush()`.
> 4. `identifyPeople(distinctId:)` stamps the unidentified `$delete` with `user-2`, so the new account's profile is deleted,
>    and `a` and the `people.set` from before the opt-out are sent as well.
>
> **Why it matters:** an opt-out is the app's way to say "forget what this device did", for example when a privacy consent
> is withdrawn. Data collected before the withdrawal must not be sent by a later opt-in. The Android SDK (8.12.0) empties its
> queue on opt-out.
>
> **Suggested fix:** in `optOutTracking()`, after the inserts the opt-out schedules, queue a block on `trackingQueue` that
> deletes all rows of every `PersistenceType` with `MPDB.deleteRows(_:isDeleteAll: true)`. Our fork's change is small
> (`MixpanelInstance.swift` and `MixpanelPersistence.swift`), with XCTests against a stub server (`MixpanelOptOutPurgeTests`),
> and updates the existing tests that asserted the queue survives an opt-out. Happy to open a PR if you want the behaviour
> upstream.

---

Last tag: 7.0.0
## [7.1.0](https://github.com/mixpanel/mixpanel-swift/tree/7.1.0) (2026-10-30)

### Features

- 🎉 Autocapture is now generally available — [clicks, rage clicks, and dead clicks](https://docs.mixpanel.com/docs/tracking-methods/sdks/swift#click-events) ([#796](https://github.com/mixpanel/mixpanel-swift/pull/796))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/7.0.0...7.1.0)

Last tag: 6.8.0
## [7.0.0](https://github.com/mixpanel/mixpanel-swift/tree/7.0.0) (2026-10-08)


### Breaking changes ([#793](https://github.com/mixpanel/mixpanel-swift/pull/793))

- Minimum OS versions are now iOS 15, tvOS 15, macOS 12 and watchOS 9, matching Xcode 27.
- SPM needs swift-tools-version 5.7.
- Requires MixpanelSwiftCommon 2.0.
- `json-logic-swift` is no longer a separate dependency. Feature Flags filtering now uses a copy bundled in MixpanelSwiftCommon.

### Deprecations
- `trackAutomaticEventsEnabled` is deprecated. Use `autocaptureOptions` instead.

### Older OS or Xcode
Stay on 6.x with Xcode 26. It gets security and critical fixes until April 2027.

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.8.0...7.0.0)

Last tag: 6.7.0
## [6.8.0](https://github.com/mixpanel/mixpanel-swift/tree/6.8.0) (2026-10-07)

### Fixes

- NSMallocException crash in flush pipeline (#791)
  - Every flush (timer, background and manual) now sends the whole queue in batches of up to 50, one batch in memory at a time. Previously the timer sent one batch per tick, so a large offline backlog now goes out as back-to-back requests in one pass. A `flush(completion:)` called while one is running completes after a follow-up flush, not immediately.
  - Setting `flushInterval` to `0` (manual mode) no longer triggers a flush. `MixpanelInstance.flushInterval` is deprecated; set it in `MixpanelOptions` instead.
  - `reset()` no longer deletes queued events, group updates or identified people updates. They are sent under the identity they were tracked with. Only people updates queued before `identify()` are dropped. Use `optOutTracking()` if you need to purge queued data.
  - Queued people updates keep the `$distinct_id` they were tracked with and are no longer re-stamped with the current identity at flush. For example, `identify("A")`, then `people.set(...)`, then `identify("B")` before a flush now sends as A, not B.
  - Queued `$ae_` events are now sent even if `trackAutomaticEventsEnabled` is turned off later, and unreadable rows in the local database are deleted when read instead of blocking the queue.
  - Upgrade note: people updates queued before 6.8.0 that lack a `$distinct_id`, and legacy pre-SQLite anonymous people updates, may take the current identity at flush time once, at upgrade.
- cancel pending dead-click check on any new tap (#788)
- reset rage-click history after emission (#790)

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.7.0...6.8.0)

Last tag: 6.6.1
## [6.7.0](https://github.com/mixpanel/mixpanel-swift/tree/6.7.0) (2026-09-09)

### Features

- Implement semver and date custom operators for flags runtime events (#763) ([#763](https://github.com/mixpanel/mixpanel-swift/pull/763))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.6.1...6.7.0)

Last tag: 6.6.0
## [6.6.1](https://github.com/mixpanel/mixpanel-swift/tree/6.6.1) (2026-09-08)

### Fixes

- read the React Native nativeID on the new architecture (#781) ([#781](https://github.com/mixpanel/mixpanel-swift/pull/781))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.6.0...6.6.1)

Last tag: 6.5.1
## [6.6.0](https://github.com/mixpanel/mixpanel-swift/tree/6.6.0) (2026-09-02)

### Features

- autocapture (beta) — clicks, rage clicks and dead clicks (#776) ([#776](https://github.com/mixpanel/mixpanel-swift/pull/776))

### Fixes

- Added scene delegate functionality to sample app (#769) ([#769](https://github.com/mixpanel/mixpanel-swift/pull/769))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.5.1...6.6.0)

Last tag: 6.5.0
## [6.5.1](https://github.com/mixpanel/mixpanel-swift/tree/6.5.1) (2026-07-15)

### Fixes

- Reduce flush and DB memory spikes (#751) ([#751](https://github.com/mixpanel/mixpanel-swift/pull/751))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.5.0...6.5.1)

Last tag: 6.4.1
## [6.5.0](https://github.com/mixpanel/mixpanel-swift/tree/6.5.0) (2026-07-06)

### Features

- add backupHost support for failover (parity with Android SDK) (#737) ([#737](https://github.com/mixpanel/mixpanel-swift/pull/737))
- extend Source.fallback with FallbackReason (SDK-79) (#745) ([#745](https://github.com/mixpanel/mixpanel-swift/pull/745))
- add trackScreenView and trackScreenLeave tracking methods (#741) ([#741](https://github.com/mixpanel/mixpanel-swift/pull/741))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.4.1...6.5.0)

Last tag: 6.4.0
## [6.4.1](https://github.com/mixpanel/mixpanel-swift/tree/6.4.1) (2026-06-10)

### Features

- add MixpanelOptions.excludeProperties to strip event keys (#734) ([#734](https://github.com/mixpanel/mixpanel-swift/pull/734))

### Fixes

- add missing comma in .swift-format config (#736) ([#736](https://github.com/mixpanel/mixpanel-swift/pull/736))
- global accent color issue (#727) ([#727](https://github.com/mixpanel/mixpanel-swift/pull/727))

### Chores

- align changelog extraction with rest of SDK fleet (#735) ([#735](https://github.com/mixpanel/mixpanel-swift/pull/735))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.4.0...6.4.1)

# Changelog

Last tag: 6.3.0
## [6.4.0](https://github.com/mixpanel/mixpanel-swift/tree/6.4.0) (2026-05-07)

### Features

- Feature Flag persistence (#723) ([#723](https://github.com/mixpanel/mixpanel-swift/pull/723))

### Chores

- add 30-day dependabot cooldown (#703) ([#703](https://github.com/mixpanel/mixpanel-swift/pull/703))
- Standardize the release process (#716) ([#716](https://github.com/mixpanel/mixpanel-swift/pull/716))

[Full Changelog](https://github.com/mixpanel/mixpanel-swift/compare/6.3.0...6.4.0)

