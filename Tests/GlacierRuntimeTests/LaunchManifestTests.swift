import Foundation
import GlacierRuntime
import Testing

@Test func launchManifestKeepsFirstEightAndNamesEveryExcessRow() throws {
    let rows = (1...10).map { ["bundleID": "test.app\($0)"] }
    let data = try JSONSerialization.data(withJSONObject: ["launch": rows])
    let manifest = try LaunchManifest.decode(data)
    #expect(manifest.bundleIDs == (1...8).map { "test.app\($0)" })
    #expect(manifest.problems.count == 2)
    #expect(manifest.problems[0].contains("launch[9] (test.app9)"))
    #expect(manifest.problems[1].contains("launch[10] (test.app10)"))
}

@Test func launchManifestRejectsBadRowsIndividuallyWithoutPromotingNinth() throws {
    let data = Data(#"{"launch":[{}, {"bundleID":"test.app1","key":"T"}, null, {"bundleID":"test.app2","key":"tt"}, {"bundleID":"test.app3","key":3}, {}, {}, {}, {"bundleID":"test.ninth"}]}"#.utf8)
    let manifest = try LaunchManifest.decode(data)
    #expect(manifest.bundleIDs == ["test.app1"])
    #expect(manifest.keyOverrides == ["test.app1": "T"])
    #expect(manifest.problems.count == 8)
    #expect(manifest.problems.last?.contains("test.ninth") == true)
}

@Test func launchManifestKeepsRailSeparateAndAllowsGenericKeys() throws {
    let data = Data(#"{"launch":[{"bundleID":"test.app1"},{"bundleID":"test.app2","key":"C"}],"rail":[{"bundleID":"test.other"}]}"#.utf8)
    let manifest = try LaunchManifest.decode(data)
    #expect(manifest.bundleIDs == ["test.app1", "test.app2"])
    #expect(manifest.keyOverrides == ["test.app2": "C"])
}

@Test func launchManifestNormalizesPersonalLetterKeys() throws {
    let data = Data(#"{"launch":[{"bundleID":"abnerworks.Typora","key":"t"},{"bundleID":"com.apple.iCal","key":"c"},{"bundleID":"com.apple.finder","key":"f"},{"bundleID":"com.mitchellh.ghostty","key":"g"},{"bundleID":"com.apple.Notes","key":"n"},{"bundleID":"net.shinyfrog.bear","key":"b"},{"bundleID":"com.apple.systempreferences","key":"s"},{"bundleID":"com.apple.AddressBook","key":"o"}]}"#.utf8)
    let manifest = try LaunchManifest.decode(data)
    #expect(manifest.problems.isEmpty)
    #expect(manifest.bundleIDs.compactMap { manifest.keyOverrides[$0] } == ["T", "C", "F", "G", "N", "B", "S", "O"])
}

@Test func launchManifestKeepsFirstBundleAndKeyOnDuplicates() throws {
    let data = Data(#"{"launch":[{"bundleID":"test.first"},{"bundleID":"test.first","key":"T"},{"bundleID":"test.second","key":"c"},{"bundleID":"test.third","key":"C"},{"bundleID":"test.fourth","key":"f"}]}"#.utf8)
    let manifest = try LaunchManifest.decode(data)
    #expect(manifest.bundleIDs == ["test.first", "test.second", "test.fourth"])
    #expect(manifest.keyOverrides == ["test.second": "C", "test.fourth": "F"])
    #expect(manifest.problems.count == 2)
    #expect(manifest.problems[0].contains("duplicate bundleID"))
    #expect(manifest.problems[1].contains("duplicate key C"))
}
