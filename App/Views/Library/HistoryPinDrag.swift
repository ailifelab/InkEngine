#if os(macOS)
import SwiftUI
import AppKit

// List 会接管落点事件，因此由拖动源根据同一窗口内的行位置完成本地排序。
// 只传递历史条目的 UUID；拖出固定区域不改变顺序，也不会复制或修改文稿。
struct HistoryPinDragHandle: NSViewRepresentable {
    let id: UUID
    let label: String
    let moveTo: (UUID, UUID) -> Void
    func makeNSView(context: Context) -> PinDragView { PinDragView() }
    func updateNSView(_ view: PinDragView, context: Context) {
        view.recordID = id; view.moveTo = moveTo; view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image); view.setAccessibilityLabel("拖动 " + label)
        view.setAccessibilityIdentifier("pinDrag-" + label)
    }
    final class PinDragView: NSView, NSDraggingSource {
        private final class WeakView { weak var view: PinDragView?; init(_ view: PinDragView) { self.view = view } }
        private static var handles: [WeakView] = []
        var recordID = UUID()
        var moveTo: ((UUID, UUID) -> Void)?
        private var dragging = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.handles.removeAll { $0.view == nil || $0.view === self }
            if window != nil { Self.handles.append(WeakView(self)) }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1
            for y in [bounds.midY - 3, bounds.midY, bounds.midY + 3] { path.move(to: NSPoint(x: 3, y: y)); path.line(to: NSPoint(x: bounds.width - 3, y: y)) }
            path.stroke()
        }
        override func mouseDown(with event: NSEvent) { dragging = false }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging else { return }; dragging = true
            let item = NSPasteboardItem(); item.setString(recordID.uuidString, forType: .string)
            let drag = NSDraggingItem(pasteboardWriter: item)
            drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil))
            beginDraggingSession(with: [drag], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
        func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
            dragging = false
            guard let window else { return }
            for target in Self.handles.compactMap(\.view) where target.window === window && target.recordID != recordID {
                let row = window.convertToScreen(target.convert(target.bounds, to: nil))
                // 落点横向覆盖整行，纵向必须仍在另一条固定记录内。
                if point.y >= row.minY && point.y <= row.maxY && point.x >= row.minX && point.x <= row.minX + 350 {
                    moveTo?(recordID, target.recordID); return
                }
            }
        }
    }
}
#else
import SwiftUI
import UIKit

/// 固定记录在本窗口内排序，不走文件拖放；手柄的触摸不会触发文稿按钮。
struct MobileHistoryPinDragHandle: UIViewRepresentable {
    let id: UUID
    let label: String
    let color: Color
    let moveTo: (UUID, UUID) -> Void
    func makeUIView(context: Context) -> PinDragView { PinDragView() }
    func updateUIView(_ view: PinDragView, context: Context) {
        view.recordID = id; view.moveTo = moveTo; view.tintColor = UIColor(color)
        view.accessibilityIdentifier = "pinDrag-" + label
        view.accessibilityLabel = "拖动排序 " + label
    }
    final class PinDragView: UIView {
        private final class WeakView { weak var view: PinDragView?; init(_ view: PinDragView) { self.view = view } }
        private static var handles: [WeakView] = []
        var recordID = UUID()
        var moveTo: ((UUID, UUID) -> Void)?
        private var dragGesture: UIPanGestureRecognizer?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear; isAccessibilityElement = true; accessibilityTraits = .image
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            dragGesture = gesture; addGestureRecognizer(gesture)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            Self.handles.removeAll { $0.view == nil || $0.view === self }
            if window != nil {
                Self.handles.append(WeakView(self))
                // 从手柄起手时优先排序，其他区域仍由列表正常滚动。
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView, let dragGesture { scroll.panGestureRecognizer.require(toFail: dragGesture); break }
                    ancestor = view.superview
                }
            }
        }
        override func tintColorDidChange() { super.tintColorDidChange(); setNeedsDisplay() }
        override func draw(_ rect: CGRect) {
            tintColor.withAlphaComponent(0.55).setStroke()
            let path = UIBezierPath(); path.lineWidth = 1.5
            for y in [bounds.midY - 4, bounds.midY, bounds.midY + 4] {
                path.move(to: CGPoint(x: 9, y: y)); path.addLine(to: CGPoint(x: bounds.width - 9, y: y))
            }
            path.stroke()
        }
        @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
            alpha = gesture.state == .began || gesture.state == .changed ? 0.55 : 1
            guard gesture.state == .ended, let window else { return }
            let point = gesture.location(in: window)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { print("INK_PIN_END id=\(recordID) point=\(point)") }
            #endif
            for target in Self.handles.compactMap(\.view) where target.window === window && target.recordID != recordID {
                let row = target.convert(target.bounds, to: window)
                var dropRow = row
                var ancestor = target.superview
                while let view = ancestor {
                    if let list = view as? UIScrollView {
                        let viewport = list.convert(list.bounds, to: window)
                        // iPad 的历史列表可能占满屏幕，落点区域必须跟随真实列表宽度。
                        dropRow = CGRect(x: viewport.minX, y: row.minY, width: viewport.width, height: row.height)
                        break
                    }
                    ancestor = view.superview
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { print("INK_PIN_TARGET id=\(target.recordID) rect=\(row)") }
                #endif
                if dropRow.contains(point) {
                    moveTo?(recordID, target.recordID); return
                }
            }
        }
    }
}
#endif
