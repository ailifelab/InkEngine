import XCTest
import CoreML
@testable import SpeechRuntime

final class CoreMLTensorTests: XCTestCase {
    func testReadsTransposeViewInLogicalOrder() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        pointer.initialize(from: [0, 3, 1, 4, 2, 5], count: 6)
        let array = try MLMultiArray(dataPointer: pointer, shape: [1, 2, 3], dataType: .float32, strides: [6, 1, 2], deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        XCTAssertEqual(try CoreMLTensor.floats(array), [0, 1, 2, 3, 4, 5])
    }
}
