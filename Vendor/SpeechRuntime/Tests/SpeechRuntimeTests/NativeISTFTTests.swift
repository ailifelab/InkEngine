import XCTest
@testable import SpeechRuntime

final class NativeISTFTTests: XCTestCase {
    func testMatchesPyTorchVocosReconstruction() throws {
        guard let path = ProcessInfo.processInfo.environment["INK_ISTFT_FIXTURE"] else { throw XCTSkip("Set INK_ISTFT_FIXTURE to the exported PyTorch oracle") }
        struct Fixture: Decodable { let frames: Int; let real: [Float]; let imag: [Float]; let samples: [Float] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let samples = try NativeISTFT().reconstruct(real: fixture.real, imaginary: fixture.imag, frames: fixture.frames)
        XCTAssertEqual(samples.count, fixture.samples.count)
        let error = zip(samples, fixture.samples).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(error, 0.00001, "Apple FFT must match the original Vocos waveform")
    }
}
