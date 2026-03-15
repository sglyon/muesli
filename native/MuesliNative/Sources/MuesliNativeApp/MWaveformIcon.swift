import SwiftUI

/// Center-aligned waveform bars with a sinusoidal two-peak envelope
/// that naturally suggests the letter "M". Uses |sin(πx)| over two
/// half-cycles so the peaks emerge organically, like a real audio signal.
struct MWaveformIcon: View {
    var barCount: Int = 13
    var spacing: CGFloat = 1.5

    // Sinusoidal M-envelope: |sin(πx)| sampled over [0, 2) gives two
    // smooth peaks with organic transitions. Scaled so min ~0.30, max 1.0.
    private static let multipliers: [CGFloat] = [
        0.30, 0.58, 0.85, 1.0, 0.90, 0.60, 0.30, 0.60, 0.90, 1.0, 0.85, 0.58, 0.30
    ]

    var body: some View {
        GeometryReader { geo in
            let count = min(barCount, Self.multipliers.count)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(count)
            let cornerRadius = barWidth / 2

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let barHeight = max(geo.size.height * Self.multipliers[i], barWidth)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .frame(width: barWidth, height: barHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}
