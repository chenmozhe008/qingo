import Foundation

@MainActor
final class ResultDismissTimer {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration = .seconds(15), action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
