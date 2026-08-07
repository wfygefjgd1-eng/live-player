import SwiftUI
import AVKit
import UIKit
import MediaPlayer

// =============================================================================
// 视频画面脱离 SwiftUI 布局
//
// 视频层由 mpv 的 CAMetalLayer 直接渲染，钉在 FullScreenRootController.view 底层。
// Hosting / ContentView 全透明，只叠手势与 OSD。
// =============================================================================

// MARK: - 根容器：系统 safe area 不参与布局

final class SinkContainerView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

// MARK: - 全局画面宿主（钉在 root 底层，不进 SwiftUI）

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private(set) var mpvSurface: UIView?
    private weak var container: UIView?

    private init() {}

    private func layoutSurface(in container: UIView) {
        let target = ScreenGeometry.physicalLandscapeBounds(for: container.window?.windowScene)
        let size: CGSize
        if target.width > 1, target.height > 1 {
            size = target.size
        } else {
            size = container.bounds.size
        }
        let frame = CGRect(
            x: (container.bounds.width - size.width) / 2,
            y: (container.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        mpvSurface?.frame = frame
    }

    /// 安装到 root 容器底层，直接按物理横屏尺寸铺开，避免被上层布局压成中间小框
    func install(in container: UIView) {
        self.container = container

        let mpvSurface: UIView
        if let existing = self.mpvSurface {
            mpvSurface = existing
        } else {
            mpvSurface = MPVMetalHostView(frame: container.bounds)
            self.mpvSurface = mpvSurface
        }

        if mpvSurface.superview !== container {
            mpvSurface.removeFromSuperview()
            mpvSurface.translatesAutoresizingMaskIntoConstraints = true
            mpvSurface.autoresizingMask = []
            container.insertSubview(mpvSurface, at: 0)
        } else {
            container.sendSubviewToBack(mpvSurface)
        }

        layoutSurface(in: container)
    }

    /// Activates mpv's CAMetalLayer drawable without disturbing SwiftUI.
    @discardableResult
    func showMPV() -> UIView? {
        if mpvSurface == nil, let container {
            install(in: container)
        }
        mpvSurface?.isHidden = false
        rebindPlayer()
        return mpvSurface
    }

    func rebindPlayer() {
        if let container, mpvSurface?.superview !== container {
            install(in: container)
        }
        if let container {
            layoutSurface(in: container)
        }
        if let mpvSurface, let container {
            container.sendSubviewToBack(mpvSurface)
        }
    }

    func forceFullBleed(reason: String = "") { rebindPlayer() }
    func hardRemount(reason: String = "") { rebindPlayer() }
    func install(reason: String = "") {
        if let container { install(in: container) }
    }
    func refreshLayout() {
        if let container {
            layoutSurface(in: container)
        }
    }
}

// MARK: - SwiftUI：空占位（画面在 root 底层，不由此承载）

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        _ = vm.playerLayoutEpoch
    }
}

// MARK: - UIKit 根控制器

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = SinkContainerView(frame: .zero)
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 透明：让底层视频露出来；视频层自己是黑底
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        // 1) 视频钉 root 底层
        WindowVideoSurface.shared.install(in: view)

        // 2) SwiftUI 叠在上面（透明）
        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .clear
        hosted.view.isOpaque = false
        hosted.view.clipsToBounds = false
        view.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosted.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        WindowVideoSurface.shared.refreshLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        WindowVideoSurface.shared.rebindPlayer()
        refreshSystemChrome()
    }

    func forcePhysicalFullScreen() {
        WindowVideoSurface.shared.rebindPlayer()
        refreshSystemChrome()
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

enum ScreenGeometry {
    static func physicalLandscapeBounds(for scene: UIWindowScene?) -> CGRect {
        if let scene {
            let b = scene.coordinateSpace.bounds
            if b.width >= b.height {
                return CGRect(x: 0, y: 0, width: b.width, height: b.height)
            }
            return CGRect(x: 0, y: 0, width: b.height, height: b.width)
        }
        let s = UIScreen.main.bounds
        let w = max(s.width, s.height)
        let h = min(s.width, s.height)
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
}

// MARK: - UIHostingController（透明叠层）

final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        view.layer.cornerRadius = 0
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
        view.insetsLayoutMarginsFromSafeArea = false
        view.preservesSuperviewLayoutMargins = false
        view.layoutMargins = .zero
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

final class NowPlayingController {
    static let shared = NowPlayingController()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    func update(title: String, artist: String, isPlaying: Bool) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        infoCenter.nowPlayingInfo = info
    }

    func updateElapsedTime(_ time: TimeInterval) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        infoCenter.nowPlayingInfo = info
    }

    func updatePlaybackRate(_ rate: Float) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        infoCenter.nowPlayingInfo = info
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
    static let tvPlayerInterruptionBegan = Notification.Name("tvPlayerInterruptionBegan")
    static let tvPlayerInterruptionEnded = Notification.Name("tvPlayerInterruptionEnded")
}
