import XCTest
import KernelStore

final class KernelStoreTests: XCTestCase {
    func testPublishedKernelRemainsStableWhileWriterPublishes() throws {
        let store = try XCTUnwrap(si01_kernel_store_create(4))
        defer { si01_kernel_store_destroy(store) }

        let first = [1.0, 2.0, 3.0, 4.0]
        let firstPublished = first.withUnsafeBufferPointer {
            si01_kernel_publish(store, $0.baseAddress, $0.count)
        }
        XCTAssertTrue(firstPublished)

        let reader = try XCTUnwrap(si01_kernel_read_begin(store))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: reader, count: 4)), first)
        for value in 10...30 {
            let next = [Double](repeating: Double(value), count: 4)
            let ok = next.withUnsafeBufferPointer {
                si01_kernel_publish(store, $0.baseAddress, $0.count)
            }
            XCTAssertTrue(ok)
        }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: reader, count: 4)), first)
        si01_kernel_read_end(store)

        let latest = try XCTUnwrap(si01_kernel_read_begin(store))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: latest, count: 4)), [30, 30, 30, 30])
        si01_kernel_read_end(store)
    }

    func testJobSlotCannotBeOverwrittenWhileWorkerOwnsIt() throws {
        let state = try XCTUnwrap(si01_job_state_create())
        defer { si01_job_state_destroy(state) }
        XCTAssertTrue(si01_job_begin_write(state))
        si01_job_finish_write(state)
        XCTAssertTrue(si01_job_is_pending(state))
        XCTAssertTrue(si01_job_take(state))
        XCTAssertFalse(si01_job_begin_write(state))
        si01_job_finish_read(state)
        XCTAssertFalse(si01_job_is_pending(state))
        XCTAssertTrue(si01_job_begin_write(state))
        si01_job_finish_write(state)
        XCTAssertTrue(si01_job_take(state))
        si01_job_finish_read(state)
    }
}
