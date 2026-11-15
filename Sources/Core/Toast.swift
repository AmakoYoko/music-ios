import Foundation
import Observation

/// Bannières façon iOS (remplacent les toasts du socle).
@MainActor @Observable final class Toast {
    enum Kind { case ok, err, warn, info }
    struct Item: Identifiable, Equatable {
        let id = UUID(); var text: String; var kind: Kind; var action: String?; var run: (() -> Void)?
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }
    static let shared = Toast()
    var current: Item?
    private var task: Task<Void, Never>?

    static func show(_ text: String, _ kind: Kind = .info, action: String? = nil, seconds: Double = 3, run: (() -> Void)? = nil) {
        Task { @MainActor in shared.present(Item(text: text, kind: kind, action: action, run: run), seconds) }
    }
    private func present(_ i: Item, _ s: Double) {
        current = i
        task?.cancel()
        task = Task { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); if !Task.isCancelled { current = nil } }
    }
}
