import ComposableArchitecture
import CryptoKit
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct LicenseTests {
  nonisolated static let key = "SUPACODE-AAAAAAAAAAAAAAAAAAAAAAAAAA-AAAAAAAAAAAAAAAAAAAAAAAAAA"
  nonisolated static let device = LicenseDevice(
    id: "test-device", name: "Test Mac", appVersion: "1.0")

  @Test func reservesOnlyFiveCreationsAndChargesOnlyCompletedWork() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permits = try await withThrowingTaskGroup(of: LicenseCreationPermit.self) { group in
      for _ in 0..<5 {
        group.addTask { try await session.authorizeCreation(resource: nil) }
      }
      var permits: [LicenseCreationPermit] = []
      for try await permit in group { permits.append(permit) }
      return permits
    }
    await #expect(throws: LicenseError.trialCreationsPending) {
      try await session.authorizeCreation(resource: nil)
    }
    #expect(stored.value.trialCreations == 0)
    _ = try await session.completeCreation(permits[0])
    _ = try await session.completeCreation(permits[0])
    #expect(stored.value.trialCreations == 1)
    for permit in permits.dropFirst() { await session.cancelCreation(permit) }
    let reloaded = Self.session(stored: stored)
    #expect(try await reloaded.load().remainingCreations == 4)
    let next = try await session.authorizeCreation(resource: nil)
    await session.cancelCreation(next)
    #expect(stored.value.trialCreations == 1)
  }

  @Test func requiresALicenseAfterFiveCompletedCreations() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    for _ in 0..<5 {
      let permit = try await session.authorizeCreation(resource: nil)
      _ = try await session.completeCreation(permit)
    }
    #expect(stored.value.trialCreations == 5)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test func rejectsConcurrentRequestsForTheSameBranch() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: "repository:feature")
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.authorizeCreation(resource: "repository:feature")
    }
    await session.cancelCreation(permit)
    _ = try await session.authorizeCreation(resource: "repository:feature")
    #expect(stored.value.trialCreations == 0)
  }

  @Test func recoversSuccessfulCreationAfterAnInterruptedCopy() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = LockIsolated(LicenseRecord())
    let original = Self.session(stored: stored)
    let permit = try await original.authorizeCreation(resource: nil)
    try await original.claimCreationResource(
      permit, resource: "repository:feature", localDirectory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    let restarted = Self.session(stored: stored)
    #expect(try await restarted.load().trialCreations == 1)
    #expect(stored.value.pendingWorktreePaths == nil)
  }

  @Test func journalsCreationIntoAnExistingEmptyDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: nil)
    try await session.claimCreationResource(
      permit, resource: "repository:first", localDirectory: directory)
    let other = try await session.authorizeCreation(resource: nil)
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.claimCreationResource(
        other, resource: "repository:second", localDirectory: directory)
    }
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    #expect(try await Self.session(stored: stored).load().trialCreations == 1)
  }

  @Test(.dependencies) func cancellationChargesOnlyWhenTheCreatedWorktreeSurvives() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let worktree = Worktree(
      location: .local(workingDirectory: directory, repositoryRoot: directory), kind: .git,
      name: "feature", detail: "", isAttached: false)
    let pending: Worktree.ID = "pending:license-cleanup"
    let permit = LicenseCreationPermit(id: UUID())
    var state = RepositoriesFeature.State()
    state.cancelRequestedPendingIDs = [pending]
    state.licensePermits[pending] = permit
    let completed = LockIsolated(0)
    let cancelled = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in directory }
      $0[LicenseClient.self].completeCreation = { _ in
        completed.withValue { $0 += 1 }
        return LicenseSnapshot()
      }
      $0[LicenseClient.self].cancelCreation = { _ in cancelled.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off
    await store.send(
      .createRandomWorktreeSucceeded(
        worktree, repositoryID: RepositoryID(directory.path), pendingID: pending))
    await store.receive(\.presentAlert)
    await store.receive(\.delegate)
    await store.finish()
    #expect(completed.value == 1)
    #expect(cancelled.value == 0)
  }

  @Test func recoversUnusedReservationWithoutCharging() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: nil)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try await session.claimCreationResource(
      permit, resource: "repository:feature", localDirectory: directory)
    #expect(try await Self.session(stored: stored).load().trialCreations == 0)
  }

  @Test func rejectsTwoRandomReservationsResolvingToTheSameBranch() async throws {
    let session = Self.session(stored: LockIsolated(LicenseRecord()))
    let first = try await session.authorizeCreation(resource: nil)
    let second = try await session.authorizeCreation(resource: nil)
    try await session.claimCreationResource(first, resource: "repository:feature")
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.claimCreationResource(second, resource: "repository:feature")
    }
  }

  @Test(.dependencies) func ignoresStaleSnapshotResponses() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    var fresh = LicenseSnapshot()
    fresh.trialCreations = 4
    fresh.updateSequence = 2
    await store.send(.snapshotUpdated(fresh)) { $0.apply(fresh) }
    var stale = LicenseSnapshot()
    stale.trialCreations = 2
    stale.updateSequence = 1
    await store.send(.snapshotUpdated(stale))
    #expect(store.state.snapshot.trialCreations == 4)
  }

  @Test func retriesAStorageFailureBeforeAuthorizingMoreWork() async throws {
    let stored = LockIsolated(LicenseRecord())
    let fails = LockIsolated(true)
    let session = LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value },
        save: { record in
          if fails.value { throw LicenseError.storageUnavailable }
          stored.withValue { $0 = record }
        }
      ),
      device: Self.device, isEnforced: true
    )
    let permit = try await session.authorizeCreation(resource: nil)
    await #expect(throws: LicenseError.storageUnavailable) {
      try await session.completeCreation(permit)
    }
    await #expect(throws: LicenseError.storageUnavailable) {
      try await session.authorizeCreation(resource: nil)
    }
    fails.withValue { $0 = false }
    _ = try await session.authorizeCreation(resource: nil)
    #expect(stored.value.trialCreations == 1)
  }

  @Test func retainsOwnedReleaseAccessIndefinitelyOffline() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey, updatesThrough: "2020-01-01")
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored,
      publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2019-12-31")
    )
    await #expect(throws: LicenseError.service("Offline")) { try await session.refresh() }
    #expect(try await session.load().ownsCurrentRelease)
    let permit = try await session.authorizeCreation(resource: nil)
    _ = try await session.completeCreation(permit)
    #expect(stored.value.trialCreations == 5)
  }

  @Test func aNewerUnownedReleaseRequiresActivationOrRenewal() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey, updatesThrough: "2026-08-01")
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2026-08-02")
    )
    #expect(try await !session.load().ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test(arguments: [false, true])
  func legacyTeamTokensRetainOwnedReleaseAccessOffline(hasLease: Bool) async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(
      signingKey: signingKey, updatesThrough: "2020-01-01", team: true,
      lease: hasLease ? 2 : nil
    )
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2019-12-31")
    )
    await #expect(throws: LicenseError.service("Offline")) { try await session.refresh() }
    #expect(try await session.load().ownsCurrentRelease)
    let permit = try await session.authorizeCreation(resource: nil)
    _ = try await session.completeCreation(permit)
    #expect(stored.value.trialCreations == 5)
  }

  @Test func legacyTeamTokenDoesNotOwnNewerReleases() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(
      signingKey: signingKey, updatesThrough: "2020-01-01", team: true, lease: 2)
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2020-01-02")
    )
    #expect(try await !session.load().ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test(arguments: ["revoked", "transferred", "deactivated"])
  func cachedTeamAccessEndsAfterASuccessfulServerRefresh(status: String) async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let cached = try Self.token(signingKey: signingKey, team: true, lease: 2)
    let updated = try Self.token(signingKey: signingKey, status: status, revision: 2)
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: cached, trialCreations: 5))
    let session = LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value }, save: { updated in stored.withValue { $0 = updated } }),
      device: Self.device, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2026-10-10"), isEnforced: true,
      request: { _, _, _ in updated }
    )
    #expect(try await session.load().ownsCurrentRelease)
    let refreshed = try await session.refresh()
    #expect(refreshed.entitlement?.status.rawValue == status)
    #expect(!refreshed.ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test func verifiesTheDeviceAndRejectsAlteredTokens() throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey)
    let codec = try LicenseEntitlementCodec(
      publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation)
    let licenseID = try #require(LicenseCredential(Self.key)?.licenseID)
    #expect(
      codec.decode(token: token, expectedDeviceID: Self.device.id, expectedLicenseID: licenseID)
        != nil)
    #expect(
      codec.decode(token: token, expectedDeviceID: "another-mac", expectedLicenseID: licenseID)
        == nil)
    #expect(
      codec.decode(
        token: "A" + token.dropFirst(), expectedDeviceID: Self.device.id,
        expectedLicenseID: licenseID)
        == nil)
    #expect(LicenseCredential(Self.key.replacing("SUPACODE", with: "SUPATERM")) == nil)
  }

  @Test(.dependencies) func activationFailureClearsTheBusyState() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    await store.send(.binding(.set(\.keyInput, "invalid"))) { $0.keyInput = "invalid" }
    await store.send(.activate) { $0.isBusy = true }
    await store.receive(\.completed) {
      $0.isBusy = false
      $0.errorMessage = LicenseError.invalidKey.localizedDescription
    }
  }

  @Test(.dependencies) func exhaustedAllowanceNeverStartsLocalGitCreation() async {
    let repository = Repository(
      location: .local(URL(fileURLWithPath: "/tmp/license-test-repository")), kind: .git,
      name: "Test", worktrees: []
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let calls = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[LicenseClient.self].isEnforced = true
      $0[LicenseClient.self].authorizeCreation = { _ in throw LicenseError.licenseRequired }
      $0[GitClientDependency.self].createWorktreeStream = { _, _, _, _, _, _, _ in
        calls.withValue { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id, nameSource: .explicit("feature"),
        baseRefSource: .repositorySetting, fetchOrigin: false
      ))
    await store.receive(\.worktreeCreationRejected)
    await store.receive(\.delegate)
    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(calls.value == 0)
  }

  @Test(.dependencies, arguments: [0, 5], [false, true])
  func sshCreationDoesNotUseTheLocalAllowance(trialCreations: Int, creationFails: Bool) async {
    let host = RemoteHost(alias: "license-test-host")
    let repository = Repository(
      location: .remote(host, path: "/home/me/repo"), kind: .git,
      name: "Test", worktrees: [])
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let stored = LockIsolated(LicenseRecord(trialCreations: trialCreations))
    let session = Self.session(stored: stored)
    let licenseCalls = LockIsolated(0)
    let commands = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature().worktreeCreateInRepoReducer
    } withDependencies: {
      $0[LicenseClient.self].isEnforced = true
      $0[LicenseClient.self].authorizeCreation = { resource in
        licenseCalls.withValue { $0 += 1 }
        return try await session.authorizeCreation(resource: resource)
      }
      $0[LicenseClient.self].claimCreationResource = { permit, resource, directory in
        licenseCalls.withValue { $0 += 1 }
        try await session.claimCreationResource(
          permit, resource: resource, localDirectory: directory)
      }
      $0[LicenseClient.self].completeCreation = { permit in
        licenseCalls.withValue { $0 += 1 }
        return try await session.completeCreation(permit)
      }
      $0[LicenseClient.self].cancelCreation = { permit in
        licenseCalls.withValue { $0 += 1 }
        await session.cancelCreation(permit)
      }
      $0.shellClient.run = { executable, arguments, directory in
        #expect(executable.path == "/usr/bin/ssh")
        #expect(directory == nil)
        let command = arguments.last ?? ""
        commands.withValue { $0.append(command) }
        if creationFails, command.contains("worktree"), command.contains("add") {
          throw ShellClientError(
            command: command, stdout: "", stderr: "Remote creation failed", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    }
    let pendingID: Worktree.ID = "pending:ssh-license-test"
    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id, nameSource: .explicit("feature"),
        baseRefSource: .explicit("HEAD"), fetchOrigin: false,
        placement: WorktreePlacementOverride(path: "/home/me/worktrees"), pendingID: pendingID))
    if creationFails {
      let error = GitClientError.commandFailed(
        command:
          "/usr/bin/env git -C /home/me/repo worktree add /home/me/worktrees/feature/ -b feature HEAD",
        message: "stderr:\nRemote creation failed")
      await store.receive(\.worktreeCreationRejected) {
        $0.alert = AlertState {
          TextState("Unable to create worktree")
        } actions: {
          ButtonState(role: .cancel) { TextState("OK") }
        } message: {
          TextState(error.localizedDescription)
        }
      }
    } else {
      await store.receive(\.remoteWorktreeCreationCompleted)
      await store.receive(\.loadPersistedRepositories)
    }
    await store.finish()
    #expect(
      commands.value.contains {
        $0.contains("worktree") && $0.contains("/home/me/worktrees/feature")
      })
    #expect(licenseCalls.value == 0)
    #expect(stored.value.trialCreations == trialCreations)
    #expect(stored.value.pendingWorktreePaths == nil)
    #expect(store.state.licensePermits.isEmpty)
  }

  @Test func activationLinksAreParsedAndRedacted() throws {
    let url = try #require(URL(string: "supacode://activate?key=\(Self.key)"))
    #expect(DeeplinkClient.liveValue.parse(url) == .activateLicense(key: Self.key))
    #expect(DeeplinkClient.loggingDescription(url) == "supacode://activate")
  }

  private nonisolated static func session(
    stored: LockIsolated<LicenseRecord>,
    publicKey: Data = Data(base64Encoded: LicenseBuild.publicKey)!,
    releaseDay: LicenseDay? = LicenseDay("2026-10-10"),
    isEnforced: Bool = true
  ) -> LicenseSession {
    LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value }, save: { updated in stored.withValue { $0 = updated } }),
      device: Self.device, publicKey: publicKey, releaseDay: releaseDay, isEnforced: isEnforced,
      request: { _, _, _ in throw LicenseError.service("Offline") }
    )
  }

  private nonisolated static func token(
    signingKey: Curve25519.Signing.PrivateKey, updatesThrough: String = "2027-10-10",
    team: Bool = false, lease: Int64? = nil,
    status: String = "active", revision: Int = 1
  ) throws -> String {
    var claims: [String: Any] = [
      "v": team ? 2 : 1, "lid": String(repeating: "0", count: 32),
      "did": Self.device.id,
      "status": status, "rev": revision, "iat": 1,
    ]
    if status == "active" { claims["upd"] = updatesThrough }
    if status == "revoked" { claims["reason"] = "refund" }
    if team {
      claims["team"] = true
      claims["lease"] = lease
    }
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let signature = try signingKey.signature(for: payload)
    return Self.base64URL(payload) + "." + Self.base64URL(signature)
  }

  private nonisolated static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing(
      "=", with: "")
  }
}
