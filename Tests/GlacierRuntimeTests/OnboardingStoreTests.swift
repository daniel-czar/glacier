import Foundation
import Testing
@testable import GlacierRuntime

@Test func onboardingStorePolicyAndResume() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlacierOnboardingStore(supportDirectory: directory)
    #expect(try store.shouldPresent(settingsExists: false))
    #expect(try !store.shouldPresent(settingsExists: true))

    let partial = GlacierOnboardingState(currentStep: .intelligence)
    try store.save(partial)
    #expect(try store.load() == partial)
    #expect(try store.shouldPresent(settingsExists: true))

    let complete = GlacierOnboardingState(currentStep: .ready, completed: true)
    try store.save(complete)
    #expect(try store.load() == complete)
    #expect(try !store.shouldPresent(settingsExists: false))
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    let data = try Data(contentsOf: store.url)
    #expect(String(decoding: data, as: UTF8.self).contains("apiKey") == false)
    #expect(String(decoding: data, as: UTF8.self).contains("clipboard") == false)
}

@Test func onboardingStoreRejectsUnsupportedVersionAndSymlink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = GlacierOnboardingStore(supportDirectory: directory)
    try Data("{\"schemaVersion\":99,\"currentStep\":\"welcome\",\"completed\":false}".utf8).write(to: store.url)
    #expect(throws: GlacierOnboardingStoreError.self) { try store.load() }
    try FileManager.default.removeItem(at: store.url)
    let target = directory.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
    #expect(throws: GlacierOnboardingStoreError.self) { try store.load() }
    #expect(throws: GlacierOnboardingStoreError.self) { try store.save(.init()) }
}
