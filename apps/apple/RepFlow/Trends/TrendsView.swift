import SwiftUI

/// 趋势页入口。正式内容由 #156 实现，这里先占住 Tab 位置
struct TrendsView: View {
    let userID: UUID

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "趋势即将上线", systemImage: "chart.line.uptrend.xyaxis",
                description: Text("这里会按周、按月展示训练量和各肌群的变化。")
            )
            .pageBackground()
            .navigationTitle("趋势")
        }
    }
}
