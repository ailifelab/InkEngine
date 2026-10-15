import Foundation
import Accelerate

/// Vocos center-padded, periodic-Hann ISTFT, matching torch.istft exactly.
/// Only the Fourier reconstruction runs here; neural layers remain Core ML.
final class NativeISTFT {
    private let setup: vDSP_DFT_Setup
    private let size = 1024, hop = 256
    private let window: [Float]
    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 1024, .INVERSE) else { throw SpeechFailure.initialization }
        self.setup = setup
        window = (0..<1024).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 1024) }
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func reconstruct(real: [Float], imaginary: [Float], frames: Int) throws -> [Float] {
        guard frames >= 2, real.count == 513 * frames, imaginary.count == real.count,
              real.allSatisfy(\.isFinite), imaginary.allSatisfy(\.isFinite) else { throw SpeechFailure.generation }
        let length = (frames - 1) * hop + size
        var summed = [Float](repeating: 0, count: length), envelope = summed
        var ri = [Float](repeating: 0, count: size), ii = ri, ro = ri, io = ri
        for frame in 0..<frames {
            for bin in 0...512 { ri[bin] = real[bin * frames + frame]; ii[bin] = imaginary[bin * frames + frame] }
            ii[0] = 0; ii[512] = 0
            for bin in 513..<size { ri[bin] = ri[size - bin]; ii[bin] = -ii[size - bin] }
            vDSP_DFT_Execute(setup, ri, ii, &ro, &io)
            let start = frame * hop
            for sample in 0..<size {
                summed[start + sample] += ro[sample] / Float(size) * window[sample]
                envelope[start + sample] += window[sample] * window[sample]
            }
        }
        let end = length - size / 2
        var pcm = [Float](); pcm.reserveCapacity(end - size / 2)
        for index in size / 2..<end {
            guard envelope[index] > 1e-11 else { throw SpeechFailure.generation }
            pcm.append(summed[index] / envelope[index])
        }
        guard pcm.allSatisfy(\.isFinite) else { throw SpeechFailure.generation }
        return pcm
    }
}
