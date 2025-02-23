import SwiftUI
import MetalKit

struct MetalView: UIViewRepresentable {
    var position: CGPoint
    var scale: CGFloat
    var offset: CGPoint
    var rotation: CGFloat   // New rotation property
    
    func makeCoordinator() -> Renderer {
        Renderer(self)
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1) // Subtle off-white
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.layer.cornerRadius = 16
        mtkView.clipsToBounds = true
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.position = position
        context.coordinator.scale = scale
        context.coordinator.offset = offset
        context.coordinator.rotation = rotation  // Forward rotation
    }
}

struct RenderConfig {
    var gridColor: SIMD4<Float>
    var arrowColor: SIMD4<Float>
    var pathColor: SIMD4<Float>
    var backgroundColor: SIMD4<Float>
}

class Renderer: NSObject, MTKViewDelegate {
    var parent: MetalView
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var position: CGPoint = .zero
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
    var rotation: CGFloat = 0  // New rotation property in renderer
    var vertexBuffer: MTLBuffer?
    private var pathTexture: MTLTexture?
    private var pathBuffer: MTLBuffer?
    private var pathPositions: [SIMD2<Float>] = []
    private var computePipelineState: MTLComputePipelineState?
    private var pathPipelineState: MTLRenderPipelineState?
    private var viewport: CGSize = .zero
    private var gridPipelineState: MTLRenderPipelineState?
    private var gridBuffer: MTLBuffer?
    private var gridVertexCount = 0
    private let gridSpacing: Float = 0.2  // Smaller, more consistent grid
    private let gridLineWidth: Float = 0.002
    private var renderConfig: RenderConfig
    
    init(_ parent: MetalView) {
        // Initialize render config with colors
        self.renderConfig = RenderConfig(
            gridColor: SIMD4<Float>(0.3, 0.3, 0.3, 0.4),  // Subtle grid
            arrowColor: SIMD4<Float>(0.0, 0.47, 1.0, 0.9), // Main arrow
            pathColor: SIMD4<Float>(0.8, 0.8, 0.8, 0.3),   // Path trace
            backgroundColor: SIMD4<Float>(0.12, 0.12, 0.12, 1.0) // Dark background
        )
        
        self.parent = parent
        super.init()
        
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Reordered vertices for triangle strip
        let vertices: [VertexIn] = [
            // Arrow shape optimized for triangle strip
            VertexIn(position: SIMD2<Float>(-0.04, 0.0)),    // Left base
            VertexIn(position: SIMD2<Float>(0.0, 0.08)),     // Top tip
            VertexIn(position: SIMD2<Float>(0.04, 0.0)),     // Right base
            VertexIn(position: SIMD2<Float>(0.0, -0.04)),    // Bottom point
            VertexIn(position: SIMD2<Float>(-0.04, 0.0)),    // Back to left base
        ]
        
        let size = MemoryLayout<VertexIn>.stride * vertices.count
        vertexBuffer = device.makeBuffer(bytes: vertices, length: size, options: [])
        
        createPipelineState()   // for arrow rendering
        createPathTexture()
        createComputePipeline()
        createPathPipeline()
        createGridBuffer()
        createGridPipeline()
    }
    
    func createPipelineState() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
    }
    
    private func createPathTexture() {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1024,
            height: 1024,
            mipmapped: false)
        textureDescriptor.usage = [.shaderWrite, .shaderRead]
        pathTexture = device.makeTexture(descriptor: textureDescriptor)
    }
    
    private func createComputePipeline() {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "updatePathTexture") else { return }
        
        do {
            computePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("Failed to create compute pipeline: \(error)")
        }
    }
    
    private func createPathPipeline() {
        guard let library = device.makeDefaultLibrary() else { return }
        let vertexFunction = library.makeFunction(name: "pathVertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            pathPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create path pipeline: \(error)")
        }
    }
    
    private func createGridBuffer() {
        var lines = [SIMD2<Float>]()
        let gridSize: Float = 2.0
        
        // Create evenly spaced grid lines
        for i in -10...10 {
            let pos = Float(i) * gridSpacing
            // Vertical lines
            if pos >= -gridSize && pos <= gridSize {
                lines.append(SIMD2<Float>(pos, -gridSize))
                lines.append(SIMD2<Float>(pos, gridSize))
            }
            // Horizontal lines
            if pos >= -gridSize && pos <= gridSize {
                lines.append(SIMD2<Float>(-gridSize, pos))
                lines.append(SIMD2<Float>(gridSize, pos))
            }
        }
        
        gridVertexCount = lines.count
        let length = MemoryLayout<SIMD2<Float>>.stride * gridVertexCount
        gridBuffer = device.makeBuffer(bytes: lines, length: length, options: [])
    }
    
    private func createGridPipeline() {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "pathVertexShader"), // reuse
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else { return }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            gridPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create grid pipeline: \(error)")
        }
    }
    
    func updatePath(with position: CGPoint) {
        let pos = SIMD2<Float>(Float(position.x), Float(position.y))
        pathPositions.append(pos)
        
        let size = MemoryLayout<SIMD2<Float>>.stride * pathPositions.count
        pathBuffer = device.makeBuffer(bytes: pathPositions, length: size, options: [])
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewport = size
    }
    
    func worldToScreenCoordinates(_ position: SIMD2<Float>) -> SIMD2<Float> {
        let screenScale = Float(scale)
        let viewportAspect = Float(viewport.width / viewport.height)
        let x = position.x * screenScale + Float(offset.x) / Float(viewport.width) * 2
        let y = position.y * screenScale + Float(offset.y) / Float(viewport.height) * 2
        return SIMD2<Float>(x * viewportAspect, y)
    }
    
    func updateColorScheme(isDark: Bool) {
        if isDark {
            renderConfig = RenderConfig(
                gridColor: SIMD4<Float>(0.3, 0.3, 0.3, 0.4),
                arrowColor: SIMD4<Float>(0.0, 0.47, 1.0, 0.9),
                pathColor: SIMD4<Float>(0.8, 0.8, 0.8, 0.3),
                backgroundColor: SIMD4<Float>(0.12, 0.12, 0.12, 1.0)
            )
        } else {
            renderConfig = RenderConfig(
                gridColor: SIMD4<Float>(0.7, 0.7, 0.7, 0.4),
                arrowColor: SIMD4<Float>(0.0, 0.47, 1.0, 0.9),
                pathColor: SIMD4<Float>(0.2, 0.2, 0.2, 0.3),
                backgroundColor: SIMD4<Float>(0.95, 0.95, 0.97, 1.0)
            )
        }
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        
        // Update path texture remains unchanged...
        let computeEncoder = commandBuffer?.makeComputeCommandEncoder()
        computeEncoder?.setComputePipelineState(computePipelineState!)
        computeEncoder?.setTexture(pathTexture, index: 0)
        var currentPos = SIMD2<Float>(Float(position.x), Float(position.y))
        computeEncoder?.setBytes(&currentPos, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        let threadgroupSize = MTLSizeMake(16, 16, 1)
        let threadgroups = MTLSizeMake(pathTexture!.width / 16, pathTexture!.height / 16, 1)
        computeEncoder?.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder?.endEncoding()
        
        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        
        // Set a factor to scale the device movement to canvas coordinates
        let canvasMovementFactor: Float = 0.001  // Adjust as needed
        
        // Calculate device (raw) offset and user offset
        let deviceOffset = SIMD2<Float>(Float(position.x), Float(position.y)) * canvasMovementFactor
        let userOffset = SIMD2<Float>(Float(offset.x), Float(offset.y))
        
        // Grid transform (static, only affected by user pan/zoom)
        var gridTransform = Transform(
            scale: Float(scale),
            offset: userOffset,
            viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            rotation: 0
        )
        
        // Moving arrow/path transform uses both deviceOffset (scaled) and user offset, and applies rotation.
        var moveTransform = Transform(
            scale: Float(scale),
            offset: deviceOffset + userOffset,
            viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
            rotation: Float(rotation)
        )
        
        // Set background color from config
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(renderConfig.backgroundColor.x),
            green: Double(renderConfig.backgroundColor.y),
            blue: Double(renderConfig.backgroundColor.z),
            alpha: Double(renderConfig.backgroundColor.w)
        )
        
        // Drawing code updated to pass renderConfig to shaders
        renderEncoder?.setVertexBytes(&renderConfig, length: MemoryLayout<RenderConfig>.stride, index: 2)
        
        // 1) Draw grid with gridTransform
        if let gridPSO = gridPipelineState, let gridBuf = gridBuffer {
            renderEncoder?.setRenderPipelineState(gridPSO)
            renderEncoder?.setVertexBuffer(gridBuf, offset: 0, index: 0)
            renderEncoder?.setVertexBytes(&gridTransform, length: MemoryLayout<Transform>.stride, index: 1)
            renderEncoder?.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }
        
        // 2) Draw moving path using moveTransform
        if let pathBuffer = pathBuffer {
            renderEncoder?.setRenderPipelineState(pathPipelineState!)
            renderEncoder?.setVertexBuffer(pathBuffer, offset: 0, index: 0)
            renderEncoder?.setVertexBytes(&moveTransform, length: MemoryLayout<Transform>.stride, index: 1)
            renderEncoder?.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pathPositions.count)
        }
        
        // 3) Draw moving/rotating arrow using moveTransform
        renderEncoder?.setRenderPipelineState(pipelineState)
        renderEncoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder?.setVertexBytes(&moveTransform, length: MemoryLayout<Transform>.stride, index: 1)
        renderEncoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 5)
        
        renderEncoder?.endEncoding()
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }
}

struct VertexIn {
    var position: SIMD2<Float>
}

struct Transform {
    var scale: Float
    var offset: SIMD2<Float>
    var viewport: SIMD2<Float>
    var rotation: Float  // Add rotation to transform
}
