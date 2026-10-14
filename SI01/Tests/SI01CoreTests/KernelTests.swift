import XCTest
@testable import SI01Core

final class KernelTests: XCTestCase {
    func testKernel() {
        for check in kernelChecks() {
            XCTAssertTrue(check.pass, "\(check.name): \(check.detail)")
        }
    }
}
