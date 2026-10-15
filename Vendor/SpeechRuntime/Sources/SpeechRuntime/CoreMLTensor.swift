import CoreML
import Foundation

/// Core ML may return transpose views. A flat storage read is not a logical
/// row-major tensor read when strides differ from the declared shape.
enum CoreMLTensor {
    static func floats(_ tensor: MLMultiArray) throws -> [Float] {
        guard tensor.dataType == .float32 else { throw SpeechFailure.generation }
        let shape = tensor.shape.map(\.intValue), strides = tensor.strides.map(\.intValue)
        let pointer = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        var output = [Float](repeating: 0, count: tensor.count)
        for i in output.indices {
            var remaining = i, address = 0
            for axis in shape.indices.reversed() {
                address += (remaining % shape[axis]) * strides[axis]
                remaining /= shape[axis]
            }
            output[i] = pointer[address]
        }
        guard output.allSatisfy(\.isFinite) else { throw SpeechFailure.generation }
        return output
    }
}
