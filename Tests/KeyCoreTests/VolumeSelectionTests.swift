import XCTest
@testable import KeyCore

final class VolumeSelectionTests: XCTestCase {
    let a = Volume(url: URL(fileURLWithPath: "/Volumes/A"), name: "A", binding: Binding(volumeUUID: "a", serialHash: nil))
    let b = Volume(url: URL(fileURLWithPath: "/Volumes/B"), name: "B", binding: Binding(volumeUUID: "b", serialHash: nil))
    func testPrefersSelectedDiskWithoutGuessingAmongSeveral() {
        XCTAssertEqual(VolumeSelection.forEjection(preferred: b.binding, available: [a, b]), b)
        XCTAssertNil(VolumeSelection.forEjection(preferred: nil, available: [a, b]))
        XCTAssertNil(VolumeSelection.forEjection(preferred: Binding(volumeUUID: "missing", serialHash: nil), available: [a, b]))
    }
    func testAllowsSingleDiskAndHandlesNoDisk() {
        XCTAssertEqual(VolumeSelection.forEjection(preferred: nil, available: [a]), a)
        XCTAssertNil(VolumeSelection.forEjection(preferred: nil, available: []))
    }
    func testRejectsDuplicateDeviceBindings() {
        let clone = Volume(url: URL(fileURLWithPath: "/Volumes/Clone"), name: "Clone", binding: a.binding)
        XCTAssertNil(VolumeSelection.forEjection(preferred: a.binding, available: [a, clone]))
    }
}
