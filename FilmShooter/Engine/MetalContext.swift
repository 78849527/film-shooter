import Foundation
import Metal

/// Process-wide Metal objects, shared by the viewfinder and the engine bridge.
enum MetalContext {
    static let device: any MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        return device
    }()

    static let queue: any MTLCommandQueue = {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Cannot create a Metal command queue")
        }
        queue.label = "FilmShooter"
        return queue
    }()
}
