import SwiftUI

struct DebugOverlayView: View {
    let info: DebugInfo
    let isVisible: Bool

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 4) {
                row("Source", info.activeSource)
                row("LH", info.leftHand ? "YES" : "no")
                row("RH", info.rightHand ? "YES" : "no")
                row("IdxExt", String(format: "%.2f", info.indexExt))
                row("OthMax", String(format: "%.2f", info.otherMax))
                row("PtRaw", info.pointingRaw ? "YES" : "no")
                row("PtEvt", info.pointingEvent ? "FIRE!" : "—")
                row("Cube", info.cubeState)
                row("RH", info.rhMode)
                row("Scale", String(format: "%.2f", info.scale))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(8)
            .background(Color.black.opacity(0.6))
            .foregroundColor(.green)
            .cornerRadius(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 50)
            .padding(.leading, 12)
            .allowsHitTesting(false)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .foregroundColor(.green.opacity(0.7))
            Text(value)
        }
    }
}
