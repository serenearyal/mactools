import SwiftUI

/// What one screen shows while the keyboard is locked.
///
/// The mouse is the unlock path, so everything here is reachable with a
/// pointer alone: a button that needs a long press, and the printed hint for
/// the two paths that need no pointer at all.
struct LockOverlayView: View {
    let startedAt: Date
    let until: Date
    let onUnlock: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var fill: Double = 0

    private var total: TimeInterval { max(until.timeIntervalSince(startedAt), 1) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color.black.opacity(0.55)

            VStack(spacing: 28) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("Keyboard locked")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Wipe away. The mouse still works.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                }

                countdown

                holdButton

                VStack(spacing: 6) {
                    Text("or press Esc 3 times")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                    Text("The power button and Touch ID cannot be blocked.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
        .ignoresSafeArea()
        .onDisappear { holdTask?.cancel() }
    }

    // MARK: - Countdown

    private var countdown: some View {
        // 10 Hz: the ring turns once over the whole timeout, so it looks
        // smooth, and the overlay is on screen for minutes at most.
        TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
            let remaining = max(until.timeIntervalSince(context.date), 0)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: remaining / total)
                    .stroke(
                        .white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(remaining.rounded(.up)))")
                        .font(.system(size: 44, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("seconds left")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 136, height: 136)
            .animation(.linear(duration: 0.1), value: remaining)
        }
        .frame(width: 136, height: 136)
    }

    // MARK: - Hold to unlock

    private var holdButton: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.18))
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.38))
                    .frame(width: proxy.size.width * fill)
            }
            .clipShape(Capsule())
            Capsule()
                .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            HStack(spacing: 8) {
                Image(systemName: fill > 0 ? "lock.open.fill" : "lock.fill")
                    .imageScale(.medium)
                Text(fill > 0 ? "Keep holding…" : "Hold to unlock")
                    .font(.title3.weight(.medium))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 280, height: 56)
        .contentShape(Capsule())
        // A drag of zero distance is a press: `onChanged` fires while the
        // button is down, `onEnded` when it comes up. A plain `Button` would
        // unlock on a tap, and a cloth on the trackpad taps constantly.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in endHold() }
        )
        .accessibilityLabel("Hold to unlock the keyboard")
    }

    private func beginHold() {
        guard holdTask == nil else { return }
        withAnimation(.linear(duration: HoldToUnlock.duration)) { fill = 1 }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(HoldToUnlock.duration))
            guard !Task.isCancelled else { return }
            holdTask = nil
            onUnlock()
        }
    }

    private func endHold() {
        holdTask?.cancel()
        holdTask = nil
        withAnimation(.easeOut(duration: 0.2)) { fill = 0 }
    }
}
