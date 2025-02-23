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
    private let translationScale: Float = 500.0
    private var lastUpdateTime: TimeInterval?

    init() {
        startUpdates()
    }

    func startUpdates() {
        guard motionManager.isAccelerometerAvailable else { return }

        motionManager.accelerometerUpdateInterval = 1.0 / 60.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }

            // Update accelerometer display
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

            // Direct position update from accelerometer
            let acceleration = SIMD2<Float>(
                Float(data.acceleration.x),
                Float(data.acceleration.y)
            )

            // Update position
            self.currentPosition += acceleration * self.translationScale * dt

            DispatchQueue.main.async {
                self.position = CGPoint(
                    x: CGFloat(self.currentPosition.x),
                    y: CGFloat(self.currentPosition.y)
                )
                self.pathUpdated = true
            }
        }

        // Keep gyro updates for rotation only
        motionManager.startGyroUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.gyroscope = SIMD3(
                x: data.rotationRate.x,
                y: data.rotationRate.y,
                z: data.rotationRate.z
            )
            DispatchQueue.main.async {
                self.orientation += Float(data.rotationRate.z) * 0.1
            }
        }
    }

    func resetPosition() {
        currentPosition = .zero
        position = .zero
        orientation = 0
        lastUpdateTime = nil
        pathUpdated = true
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
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
    @State private var lastOffset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero
    @State private var minScale: CGFloat = 0.5
    @State private var maxScale: CGFloat = 4.0

    var body: some View {
        VStack {
            HStack {
                Button(action: {
                    motionManager.resetPosition()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title2)
                }
                .padding()

                Spacer()
                
                // Add zoom controls
                HStack(spacing: 16) {
                    Button(action: {
                        withAnimation {
                            scale = max(minScale, scale / 1.2)
                        }
                    }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.title2)
                    }
                    
                    Button(action: {
                        withAnimation {
                            scale = min(maxScale, scale * 1.2)
                        }
                    }) {
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
                        y: -(offset.height + gestureOffset.height) // Invert Y-axis
                     ),
                     rotation: CGFloat(motionManager.orientation))
                .onChange(of: motionManager.pathUpdated) { _, _ in
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = scene.windows.first,
                       let mtkView = window.rootViewController?.view as? MTKView,
                       let renderer = mtkView.delegate as? Renderer {
                        renderer.updatePath(with: motionManager.position)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(uiColor: .systemBackground),
                            Color(uiColor: .secondarySystemBackground)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                .gesture(SimultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            scale = max(minScale, min(maxScale, scale * value))
                        },
                    DragGesture(minimumDistance: 0)
                        .updating($gestureOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                            lastOffset = offset
                        }
                ))
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

