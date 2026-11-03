import SwiftUI
import UIKit

/// The live, film-graded viewfinder.
///
/// The camera frame is aspect-filled (centred crop) into the view. The view
/// sizes itself to `frameAspect` within the space it is offered.
struct ViewfinderView: UIViewRepresentable {
    let frames: CameraFrameSource
    /// The film's colour table; `nil` keeps the current one (identity at first).
    var lut: FilmLUT?
    /// Width / height of the picture as shown in portrait (e.g. 2/3, 3/4, 1).
    var frameAspect: CGFloat = 2.0 / 3.0
    /// The film's grain strength, 0...2.
    var grain: Float = 1
    /// Monochrome grain for black-and-white stocks.
    var isMonochrome: Bool = false
    /// Ignored: front-camera frames are already mirrored by the capture
    /// connection, so the preview is a mirror image without any flag.
    var mirrored: Bool = false

    func makeUIView(context: Context) -> ViewfinderMetalView {
        let view = ViewfinderMetalView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: ViewfinderMetalView, context: Context) {
        apply(to: uiView)
    }

    static func dismantleUIView(_ uiView: ViewfinderMetalView, coordinator: ()) {
        uiView.renderer.detach()
        uiView.renderer.setActive(false)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ViewfinderMetalView, context: Context) -> CGSize? {
        let aspect = frameAspect > 0 ? frameAspect : 1
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        switch (width, height) {
        case let (w?, h?):
            guard h > 0 else { return CGSize(width: w, height: 0) }
            return w / h > aspect ? CGSize(width: h * aspect, height: h) : CGSize(width: w, height: w / aspect)
        case let (w?, nil):
            return CGSize(width: w, height: w / aspect)
        case let (nil, h?):
            return CGSize(width: h * aspect, height: h)
        default:
            return nil
        }
    }

    private func apply(to view: ViewfinderMetalView) {
        view.renderer.attach(to: frames)
        view.renderer.setLook(grain: grain, monochrome: isMonochrome)
        view.renderer.setLUT(lut)
    }
}

/// A `CAMetalLayer`-backed view driven by `ViewfinderRenderer`.
final class ViewfinderMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private(set) lazy var renderer = ViewfinderRenderer(layer: layer as! CAMetalLayer)

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = true
        backgroundColor = .black
        _ = renderer
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        renderer.setActive(window != nil)
    }

    private func updateDrawableSize() {
        let traitScale = traitCollection.displayScale
        let scale = traitScale > 0 ? traitScale : 3
        if contentScaleFactor != scale { contentScaleFactor = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        renderer.setDrawableSize(size)
    }

    @objc private func appDidEnterBackground() {
        renderer.setActive(false)
    }

    @objc private func appWillEnterForeground() {
        renderer.setActive(window != nil)
    }
}
