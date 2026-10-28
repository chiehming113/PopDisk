import SwiftUI

/// 已使用空間的長條，依使用率變色
struct CapacityBar: View {
    let usedFraction: Double

    // 自己畫：ProgressView 在非作用中的視窗會變灰，tint 也不一定生效
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(geometry.size.width * min(max(usedFraction, 0), 1), 4))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityValue(Text(usedFraction, format: .percent.precision(.fractionLength(0))))
    }

    private var color: Color {
        switch usedFraction {
        case ..<0.8: .green
        case ..<0.9: .yellow
        default: .red
        }
    }
}

extension Int64 {
    /// 「可用 X，共 Y」
    /// - Parameter compact: 選單裡最多一位小數；資訊面板要精確值時傳 false
    static func capacityDescription(available: Int64, total: Int64, compact: Bool = true) -> String {
        let free = compact ? available.compactByteCount : available.formatted(.byteCount(style: .file))
        let size = compact ? total.compactByteCount : total.formatted(.byteCount(style: .file))
        return String(localized: "\(free) free of \(size)")
    }

    /// 最多一位小數的容量，例如 718.1 GB、2 TB。`.byteCount` 在 GB 以上固定兩位小數，選單裡太細；
    /// 和 `.file` 一樣用 1000 進位，數字才會和 Finder 一致
    var compactByteCount: String {
        let units: [UnitInformationStorage] = [.bytes, .kilobytes, .megabytes, .gigabytes, .terabytes, .petabytes]
        var value = Double(self)
        var index = 0
        // 先四捨五入再比，避免出現「1000 GB」
        while index < units.count - 1, (value * 10).rounded() / 10 >= 1000 {
            value /= 1000
            index += 1
        }
        return Measurement(value: value, unit: units[index]).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
        )
    }
}
