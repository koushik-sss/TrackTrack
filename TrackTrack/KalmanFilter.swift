import Foundation
import simd

class KalmanFilter {
    private var state: SIMD2<Float>  // position
    private var covariance: float2x2
    private let processNoise: float2x2
    private let measurementNoise: float2x2

    init() {
        state = SIMD2<Float>(0, 0)
        covariance = float2x2(rows: [
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 1)
        ])
        processNoise = float2x2(rows: [
            SIMD2<Float>(0.01, 0),
            SIMD2<Float>(0, 0.01)
        ])
        measurementNoise = float2x2(rows: [
            SIMD2<Float>(0.1, 0),
            SIMD2<Float>(0, 0.1)
        ])
    }

    func update(measurement: SIMD2<Float>) -> SIMD2<Float> {
        // Predict
        covariance += processNoise

        // Update
        let innovation = measurement - state
        let innovationCovariance = covariance + measurementNoise
        let kalmanGain = covariance * inverse(innovationCovariance)

        state += kalmanGain * innovation
        covariance = (float2x2(diagonal: SIMD2<Float>(1, 1)) - kalmanGain) * covariance

        return state
    }

    private func inverse(_ matrix: float2x2) -> float2x2 {
        let determinant = matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]
        let invDet = 1.0 / determinant

        return float2x2(rows: [
            SIMD2<Float>(matrix[1][1] * invDet, -matrix[0][1] * invDet),
            SIMD2<Float>(-matrix[1][0] * invDet, matrix[0][0] * invDet)
        ])
    }
}
