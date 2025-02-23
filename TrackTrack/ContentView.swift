import SwiftUI
import CoreMotion
import MetalKit

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    @Published var accelerometer: SIMD3<Double> = .zero
    @Published var gyroscope: SIMD3<Double> = .zero
    @Published var position: CGPoint = .zero
    @Published var pathUpdated: Bool = false
    @Published var orientation: Float = 0

    private var currentPosition: SIMD2<Float> = .zero
    private var currentVelocity: SIMD2<Float> = .zero
    private let positionScale: Float = 100.0
    private var lastUpdateTime: TimeInterval?
    private let rotationSensitivity: Float = 0.5
    
    // Kalman filter parameters
    private var positionUncertainty: float2x2 = float2x2(diagonal: SIMD2<Float>(1, 1))
    private let measurementUncertainty: Float = 0.1
    private let processUncertainty: Float = 0.1

    init() {
        startUpdates()
    }
    
    private func rotateVector(_ vector: SIMD2<Float>, byAngle angle: Float) -> SIMD2<Float> {
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        return SIMD2<Float>(
            vector.x * cosAngle - vector.y * sinAngle,
            vector.x * sinAngle + vector.y * cosAngle
        )
    }
    
    private func kalmanUpdate(measurement: SIMD2<Float>, uncertainty: inout float2x2) -> SIMD2<Float> {
        // Prediction
        uncertainty += float2x2(diagonal: SIMD2<Float>(processUncertainty, processUncertainty))
        
        // Kalman gain
        let kalmanGain = uncertainty.columns.0 / (uncertainty.columns.0 + measurementUncertainty)
        
        // Update
        let innovation = measurement - currentPosition
        let position = currentPosition + kalmanGain * innovation
        
        // Update uncertainty
        uncertainty *= (1 - kalmanGain)
        
        return position
    }

    func startUpdates() {
        guard motionManager.isAccelerometerAvailable else { return }

        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }

            self.accelerometer = SIMD3(
                x: data.acceleration.x,
                y: data.acceleration.y,
                z: data.acceleration.z
            )

            let currentTime = Date().timeIntervalSince1970
            let dt: Float
            if let lastTime = self.lastUpdateTime {
                dt = Float(currentTime - lastTime)
            } else {
                dt = 1.0 / 60.0
            }
            self.lastUpdateTime = currentTime

            // Get acceleration in device coordinates
            var acceleration = SIMD2<Float>(
                Float(data.acceleration.x),
                Float(data.acceleration.y)
            )
            
            // Rotate acceleration vector to world coordinates using current orientation
            acceleration = self.rotateVector(acceleration, byAngle: self.orientation)
            
            // Update velocity with rotated acceleration
            self.currentVelocity += acceleration * dt * self.positionScale
            
            // Predict new position
            let predictedPosition = self.currentPosition + self.currentVelocity * dt
            
            // Apply Kalman filter
            self.currentPosition = self.kalmanUpdate(
                measurement: predictedPosition,
                uncertainty: &self.positionUncertainty
            )

            DispatchQueue.main.async {
                self.position = CGPoint(
                    x: CGFloat(self.currentPosition.x),
                    y: CGFloat(self.currentPosition.y)
                )
                self.pathUpdated = true
            }
        }

        motionManager.gyroUpdateInterval = 1.0 / 60.0
        motionManager.startGyroUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.gyroscope = SIMD3(
                x: data.rotationRate.x,
                y: data.rotationRate.y,
                z: data.rotationRate.z
            )
            DispatchQueue.main.async {
                // Update orientation based on gyro z-axis
                self.orientation += Float(data.rotationRate.z) * self.rotationSensitivity
                // Normalize orientation to -2π to 2π
                self.orientation = self.orientation.truncatingRemainder(dividingBy: 2 * .pi)
            }
        }
    }

    func resetPosition() {
        currentPosition = .zero
        currentVelocity = .zero
        position = .zero
        orientation = 0
        lastUpdateTime = nil
        pathUpdated = true
        positionUncertainty = float2x2(diagonal: SIMD2<Float>(1, 1))
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
    }
}

// Move existing sensor view to its own struct
struct SensorDataView: View {
    @ObservedObject var motionManager: MotionManager

    var body: some View {
        VStack {
            Text("IMU Sensor Data")
                .font(.title)
                .padding()

            GroupBox("Accelerometer (g)") {
                VStack(alignment: .leading) {
                    Text(String(format: "X: %.2f", motionManager.accelerometer.x))
                    Text(String(format: "Y: %.2f", motionManager.accelerometer.y))
                    Text(String(format: "Z: %.2f", motionManager.accelerometer.z))
                }
                .padding()
            }

            GroupBox("Gyroscope (rad/s)") {
                VStack(alignment: .leading) {
                    Text(String(format: "X: %.2f", motionManager.gyroscope.x))
                    Text(String(format: "Y: %.2f", motionManager.gyroscope.y))
                    Text(String(format: "Z: %.2f", motionManager.gyroscope.z))
                }
                .padding()
            }
        }
        .padding()
    }
}

// Canvas view as separate component
struct CanvasView: View {
    @ObservedObject var motionManager: MotionManager
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var gridRotation: CGFloat = 0
    @State private var manualArrowRotation: CGFloat = 0
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero
    @GestureState private var gestureRotation: CGFloat = 0
    @State private var minScale: CGFloat = 0.5
    @State private var maxScale: CGFloat = 4.0
    @Environment(\.colorScheme) var colorScheme

    // Helper function to normalize rotation to -2π to 2π
    private func normalizeRotation(_ rotation: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        let normalized = rotation.truncatingRemainder(dividingBy: twoPi)
        return normalized
    }

    var body: some View {
        VStack {
            HStack {
                Button {
                    motionManager.resetPosition()
                    scale = 1.0
                    offset = .zero
                    gridRotation = 0
                    manualArrowRotation = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title2)
                }
                .padding()
                
                HStack(spacing: 16) {
                    Button {
                        withAnimation { scale = max(minScale, scale / 1.2) }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.title2)
                    }
                    Button {
                        withAnimation { scale = min(maxScale, scale * 1.2) }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.title2)
                    }
                }
                .padding()
            }
            
            MetalView(position: motionManager.position,
                      scale: max(minScale, min(maxScale, scale * gestureScale)),
                      offset: CGPoint(
                        x: offset.width + gestureOffset.width,
                        y: -(offset.height + gestureOffset.height)
                      ),
                      arrowRotation: normalizeRotation(CGFloat(motionManager.orientation) + manualArrowRotation + gestureRotation),
                      gridRotation: normalizeRotation(gridRotation + gestureRotation),
                      isDarkMode: colorScheme == .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: colorScheme == .dark ?
                        [Color.black, Color.gray] :
                        [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
            .overlay(alignment: .bottomTrailing) {
                Text(String(format: "%.1fx", scale * gestureScale))
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
            .gesture(
                SimultaneousGesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = max(minScale, min(maxScale, scale * value))
                            },
                        RotationGesture()
                            .updating($gestureRotation) { value, state, _ in 
                                state = -normalizeRotation(value.radians)
                            }
                            .onEnded { value in
                                gridRotation = normalizeRotation(gridRotation - value.radians)
                                manualArrowRotation = normalizeRotation(manualArrowRotation - value.radians)
                            }
                    ),
                    DragGesture(minimumDistance: 0)
                        .updating($gestureOffset) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
            )
            .onChange(of: motionManager.pathUpdated) { oldValue, newValue in
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first,
                   let mtkView = window.rootViewController?.view as? MTKView,
                   let renderer = mtkView.delegate as? Renderer {
                    renderer.updatePath(with: motionManager.position)
                }
            }
            .padding()
        }
    }
}

// Main content view with tab navigation
struct ContentView: View {
    @StateObject private var motionManager = MotionManager()

    var body: some View {
        TabView {
            SensorDataView(motionManager: motionManager)
                .tabItem {
                    Label("Sensors", systemImage: "gauge")
                }

            CanvasView(motionManager: motionManager)
                .tabItem {
                    Label("Canvas", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
        }
    }
}

#Preview {
    ContentView()
}

