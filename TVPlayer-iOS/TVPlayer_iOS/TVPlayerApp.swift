import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

@main
final class AppDelegate: NSObject, UIApplicationDelegate {

    var window: UIWindow?
    private var viewModel: PlayerViewModel?
    private weak var rootContainer: FullScreenRootController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setupAudioSession()
        setupRemoteCommands()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }

    func installMainWindow(application: UIApplication, scene: UIWindowScene? = nil) {
        guard let scene else { return }
        if let window, rootContainer != nil {
            if window.windowScene !== scene {
                window.windowScene = scene
            }
            window.frame = scene.coordinateSpace.bounds
            window.makeKeyAndVisible()
            requestLandscape(for: scene, root: rootContainer)
            rootContainer?.refreshSystemChrome()
            return
        }

        let viewModel = self.viewModel ?? PlayerViewModel()
        self.viewModel = viewModel

        let rootView = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        )
        let hosting = RootHostingController(rootView: rootView)
        let container = FullScreenRootController(hosting: hosting)
        self.rootContainer = container

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .black
        window.isOpaque = true
        window.rootViewController = container
        self.window = window
        window.makeKeyAndVisible()
        requestLandscape(for: scene, root: container)
        WindowVideoSurface.shared.rebindPlayer()
        container.refreshSystemChrome()
    }

    private func requestLandscape(for scene: UIWindowScene?, root: UIViewController?) {
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        UIViewController.attemptRotationToDeviceOrientation()
        guard let scene else { return }
        if scene.interfaceOrientation.isLandscape {
            return
        }
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            scene.requestGeometryUpdate(prefs) { error in
                print("requestGeometryUpdate failed: \(error.localizedDescription)")
            }
        }
    }

    func handleSceneWillEnterForeground(_ scene: UIWindowScene) {
        requestLandscape(for: scene, root: rootContainer)
        rootContainer?.refreshSystemChrome()
        WindowVideoSurface.shared.rebindPlayer()
    }

    func handleSceneDidBecomeActive(_ scene: UIWindowScene) {
        requestLandscape(for: scene, root: rootContainer)
        rootContainer?.refreshSystemChrome()
        viewModel?.onAppBecameActive()
        WindowVideoSurface.shared.rebindPlayer()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
        // 监听音频中断（来电/闹钟/Siri 等）：转发为业务通知，
        // 由 PlayerViewModel.noteInterruptionBegan/Ended 负责在结束后自动恢复播放。
        // 中断通知的 userInfo 里 AVAudioSessionInterruptionTypeKey 区分 .began/.ended；
        // 还有 AVAudioSessionInterruptionOptionShouldResumeKey 指示系统是否建议恢复。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            NotificationCenter.default.post(name: .tvPlayerInterruptionBegan, object: nil)
        case .ended:
            // 仅当系统建议恢复（shouldResume）时才自动 resume，避免打断（如用户拒接）
            // 后立即误恢复。
            var shouldResume = true
            if let optionRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                shouldResume = options.contains(.shouldResume)
            }
            NotificationCenter.default.post(name: .tvPlayerInterruptionEnded, object: nil, userInfo: ["shouldResume": shouldResume])
        @unknown default:
            break
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePause, object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemoteNext, object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePrevious, object: nil)
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        URLCache.shared.removeAllCachedResponses()
    }

    func refreshChromeAndVideo(reason: String) {
        WindowVideoSurface.shared.rebindPlayer()
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.installMainWindow(application: UIApplication.shared, scene: windowScene)
        (app.window?.rootViewController as? FullScreenRootController)?.refreshSystemChrome()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.handleSceneDidBecomeActive(windowScene)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.handleSceneWillEnterForeground(windowScene)
    }
}

extension Notification.Name {
    static let tvPlayerRemotePlay = Notification.Name("tvPlayerRemotePlay")
    static let tvPlayerRemotePause = Notification.Name("tvPlayerRemotePause")
    static let tvPlayerRemoteNext = Notification.Name("tvPlayerRemoteNext")
    static let tvPlayerRemotePrevious = Notification.Name("tvPlayerRemotePrevious")
    static let tvPlayerWillResignActive = Notification.Name("tvPlayerWillResignActive")
    static let tvPlayerDidEnterBackground = Notification.Name("tvPlayerDidEnterBackground")
}
