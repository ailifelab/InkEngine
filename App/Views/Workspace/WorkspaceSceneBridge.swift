#if os(iOS)
import SwiftUI
import UIKit

struct WorkspaceSceneBridge: UIViewRepresentable {
    let workspace: DocumentWorkspace
    let id: UUID
    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.connected = { [weak workspace] scene in workspace?.registerScene(scene, window: id) }
        return view
    }
    func updateUIView(_ view: SceneView, context: Context) {
        if let scene = view.window?.windowScene { workspace.registerScene(scene, window: id) }
    }
    final class SceneView: UIView {
        var connected: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { connected?(scene) }
        }
    }
}
#endif
