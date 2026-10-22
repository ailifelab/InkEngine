#if canImport(CoreML)
import CoreML
import Foundation

/// CoreML MultiCodeDecoder: autoregressive CB1-15 prediction.
/// 5-layer transformer with 15 lm_heads, scatter-write KV cache.
///
/// Supports both stateful (MLState) and stateless (explicit KV cache I/O).
/// Stateful drops per-call cache I/O (~327 KB × 2000 inner calls per 10 s clip).
final class MultiCodeDecoderCoreML {
    private let model: MLModel
    private let maxSeqLen = 16
    private let totalKVDim: Int
    private let inputWidth: Int
    private let numGroups = 15
    private let isStateful: Bool

    init(model: MLModel, inputWidth: Int = 1024, totalKVDim: Int = 5120) {
        self.inputWidth = inputWidth
        self.totalKVDim = totalKVDim
        self.model = model
        self.isStateful = !model.modelDescription.stateDescriptionsByName.isEmpty
    }

    /// Predict 15 residual codebook tokens autoregressively.
    /// - Parameters:
    ///   - hiddenState: [1, talkerWidth, 1, 1] from CodeDecoder; projection is inside the model
    ///   - cb0Token: First codebook token
    ///   - codeEmbedder: For embedding CB0
    ///   - multiCodeEmbedder: For embedding CB1-14 tokens
    func predict(
        hiddenState: MLMultiArray,
        cb0Token: Int32,
        codeEmbedder: CodeEmbedderModel,
        multiCodeEmbedder: MultiCodeEmbedderModel,
        temperature: Float = 0.9,
        topK: Int = 50
    ) throws -> [Int32] {
        // Per-predict() state. Stateful path: MLState lives only inside this
        // call so the KV cache resets cleanly across frames. Stateless path:
        // keep the explicit cache buffers in locals and round-trip them.
        let mlState: MLState? = isStateful ? model.makeState() : nil
        var keyCache: MLMultiArray? = nil
        var valueCache: MLMultiArray? = nil
        if !isStateful {
            keyCache = makeZeros(shape: [1, totalKVDim, 1, maxSeqLen])
            valueCache = makeZeros(shape: [1, totalKVDim, 1, maxSeqLen])
        }

        // Position 0: feed hidden_states from CodeDecoder
        let (_, kc0, vc0) = try step(
            embed: ensureNCHW(hiddenState, channels: inputWidth),
            position: 0, keyCache: keyCache, valueCache: valueCache, state: mlState)
        if !isStateful { keyCache = kc0; valueCache = vc0 }

        // Position 1: feed CodeEmbedder(CB0) → read lm_head[0] → CB1
        let cb0Embed = ensureNCHW(try codeEmbedder.embed(Int(cb0Token)), channels: inputWidth)
        var (logits, kc1, vc1) = try step(embed: cb0Embed, position: 1,
                                          keyCache: keyCache, valueCache: valueCache, state: mlState)
        if !isStateful { keyCache = kc1; valueCache = vc1 }

        // Sample CB1 from lm_head[0]
        let cb1Logits = extractGroupLogits(logits, group: 0)
        guard cb1Logits.allSatisfy(\.isFinite) else { throw BundleError.invalidInput("Nonfinite predictor logits") }
        var prevToken = TTSSampler.sample(logits: cb1Logits, temperature: temperature, topK: topK)
        var tokens = [prevToken]

        // Positions 2-15: autoregressive CB2-CB15
        for cbStep in 1..<numGroups {
            let embed = ensureNCHW(
                try multiCodeEmbedder.embed(codebookIdx: cbStep - 1, tokenId: Int(prevToken)),
                channels: inputWidth)
            let pos = cbStep + 1
            let (lg, kc, vc) = try step(embed: embed, position: pos,
                                        keyCache: keyCache, valueCache: valueCache, state: mlState)
            logits = lg
            if !isStateful { keyCache = kc; valueCache = vc }

            let groupLogits = extractGroupLogits(logits, group: cbStep)
            guard groupLogits.allSatisfy(\.isFinite) else { throw BundleError.invalidInput("Nonfinite predictor logits") }
            prevToken = TTSSampler.sample(logits: groupLogits, temperature: temperature, topK: topK)
            tokens.append(prevToken)
        }

        return tokens
    }

    // MARK: - Helpers

    private func step(embed: MLMultiArray, position: Int,
                      keyCache: MLMultiArray?, valueCache: MLMultiArray?, state: MLState?)
        throws -> (logits: MLMultiArray, keyCache: MLMultiArray, valueCache: MLMultiArray) {
        return try autoreleasepool {
            let cacheLen = try MLMultiArray(shape: [1], dataType: .int32)
            cacheLen.dataPointer.assumingMemoryBound(to: Int32.self)[0] = Int32(position)

            let keyMask = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .float16)
            let maskPtr = keyMask.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<maxSeqLen { maskPtr[i] = i <= position ? Float16(0) : Float16(-1e4) }

            let updateMask = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .float16)
            memset(updateMask.dataPointer, 0, maxSeqLen * 2)
            updateMask.dataPointer.assumingMemoryBound(to: Float16.self)[position] = Float16(1.0)

            var inputs: [String: MLFeatureValue] = [
                "input_embeds": MLFeatureValue(multiArray: embed),
                "cache_length": MLFeatureValue(multiArray: cacheLen),
                "key_padding_mask": MLFeatureValue(multiArray: keyMask),
                "kv_cache_update_mask": MLFeatureValue(multiArray: updateMask),
            ]
            if model.modelDescription.inputDescriptionsByName["code_group"] != nil {
                let group = try MLMultiArray(shape: [1], dataType: .int32)
                group[0] = NSNumber(value: max(0, position - 1))
                inputs["code_group"] = MLFeatureValue(multiArray: group)
            }
            // Stateless path adds explicit KV cache I/O; stateful path leaves it
            // to MLState (runtime keeps the buffers between predictions).
            if !isStateful, let kc = keyCache, let vc = valueCache {
                inputs["key_cache"] = MLFeatureValue(multiArray: kc)
                inputs["value_cache"] = MLFeatureValue(multiArray: vc)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let result: MLFeatureProvider
            if let mlState = state {
                result = try model.prediction(from: provider, using: mlState)
            } else {
                result = try model.prediction(from: provider)
            }

            let logits = result.featureValue(for: "all_logits")!.multiArrayValue!
            // Stateful models don't expose new_key_cache / new_value_cache — return
            // the input caches as placeholders (callers ignore them on stateful).
            let nkc = result.featureValue(for: "new_key_cache")?.multiArrayValue
                ?? (keyCache ?? logits)
            let nvc = result.featureValue(for: "new_value_cache")?.multiArrayValue
                ?? (valueCache ?? logits)
            return isStateful ? (logits, nkc, nvc) : (logits, try ownedCache(nkc), try ownedCache(nvc))
        }
    }

    /// Extract logits for a specific group from [1, 15, 2048] (stride-safe).
    private func extractGroupLogits(_ array: MLMultiArray, group: Int) -> [Float] {
        let vocabSize = 2048
        var result = [Float](repeating: 0, count: vocabSize)
        let ndim = array.shape.count
        let strides = array.strides.map(\.intValue)
        let selectedGroup = array.shape[ndim - 2].intValue == 1 ? 0 : group
        let base = selectedGroup * strides[ndim - 2], stride = strides[ndim - 1]
        if array.dataType == .float16 {
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<vocabSize { result[i] = Float(pointer[base + i * stride]) }
            return result
        }
        if array.dataType == .float32 {
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<vocabSize { result[i] = pointer[base + i * stride] }
            return result
        }
        for i in 0..<vocabSize {
            var idx = [NSNumber](repeating: 0, count: ndim)
            if ndim == 3 { idx[1] = group as NSNumber; idx[2] = i as NSNumber }
            else if ndim == 2 { idx[0] = group as NSNumber; idx[1] = i as NSNumber }
            result[i] = array[idx].floatValue
        }
        return result
    }

    private func makeZeros(shape: [Int]) -> MLMultiArray {
        let a = try! MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        memset(a.dataPointer, 0, shape.reduce(1, *) * 2)
        return a
    }
    /// Keep cache storage independent from reusable Core ML output buffers.
    /// The owning row-major copy also preserves GPU transpose views correctly.
    private func ownedCache(_ source: MLMultiArray) throws -> MLMultiArray {
        guard source.dataType == .float16, source.shape.map(\.intValue) == [1, totalKVDim, 1, maxSeqLen] else { throw BundleError.invalidInput("Invalid predictor cache shape") }
        let target = try MLMultiArray(shape: source.shape, dataType: .float16)
        let src = source.dataPointer.assumingMemoryBound(to: Float16.self), dst = target.dataPointer.assumingMemoryBound(to: Float16.self)
        let strides = source.strides.map(\.intValue)
        if strides[1] == maxSeqLen && strides[3] == 1 {
            memcpy(dst, src, totalKVDim * maxSeqLen * MemoryLayout<Float16>.stride)
            return target
        }
        for c in 0..<totalKVDim { for p in 0..<maxSeqLen { dst[c * maxSeqLen + p] = src[c * strides[1] + p * strides[3]] } }
        return target
    }

    /// Fast contiguous copy for 4D FP16 [1, C, 1, S] arrays with non-unit strides.

}
#endif
