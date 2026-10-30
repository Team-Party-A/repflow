import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = MotionRecorder()
    @ObservedObject var transfer: RecordingTransfer
    @State private var participant = ""
    @State private var exercise = "dumbbell_curl"
    @State private var negative = false
    @State private var scene = "standing"
    @State private var frequency = 50.0
    @State private var confirmDiscard = false

    init(transfer: RecordingTransfer = .shared) { self.transfer = transfer }

    var body: some View {
        NavigationStack {
            List {
                if recorder.phase == .idle {
                    TextField("匿名编号，如 p001", text: $participant)
                    Toggle("负样本", isOn: $negative)
                    if negative {
                        Picker("场景", selection: $scene) {
                            Text("静止站立").tag("standing")
                            Text("走动").tag("walking")
                            Text("拿放器械").tag("handling_equipment")
                        }
                    } else {
                        Picker("动作", selection: $exercise) {
                            ForEach(ExerciseCatalog.all) { Text($0.displayName).tag($0.id) }
                        }
                    }
                    Picker("采样率", selection: $frequency) {
                        Text("50 Hz").tag(50.0)
                        Text("25 Hz").tag(25.0)
                    }
                    Button("开始录制") {
                        recorder.start(
                            participant: participant,
                            activity: negative ? scene : exercise,
                            negative: negative, frequency: frequency)
                    }
                    Text("仅采集研究数据，不保存为健康 App 或 RepFlow 训练记录。")
                        .font(.footnote)
                } else {
                    Text("\(recorder.sampleCount) 点 · \(recorder.elapsed, specifier: "%.1f") 秒")
                    if recorder.phase == .leadIn && !negative {
                        Button("开始本组") { recorder.beginSet() }
                            .disabled(recorder.sampleCount < 2)
                    }
                    if recorder.phase == .activeSet {
                        Button("结束本组") { recorder.endSet() }
                    }
                    if recorder.phase == .tail || (negative && recorder.phase == .leadIn)
                        || recorder.phase == .stopped
                    {
                        Button(recorder.phase == .stopped ? "重试保存" : "停止并保存") {
                            if let file = recorder.stopAndSave() {
                                transfer.refresh()
                                transfer.send(file)
                            }
                        }.disabled(recorder.sampleCount < 2)
                    }
                    Button("放弃本次录制", role: .destructive) { confirmDiscard = true }
                }
                if !recorder.message.isEmpty { Text(recorder.message).font(.footnote) }
                if !transfer.status.isEmpty { Text(transfer.status).font(.footnote) }
                if recorder.phase == .idle {
                    Section("已保存在手表") {
                        ForEach(transfer.files, id: \.self) { file in
                            Button {
                                transfer.send(file)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(file.deletingPathExtension().lastPathComponent).font(
                                        .caption2)
                                    Text("发送到手机")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("传感器录制")
            .confirmationDialog("放弃未保存的数据？", isPresented: $confirmDiscard) {
                Button("放弃录制", role: .destructive) { recorder.discard() }
            }
        }
    }
}

#Preview {
    ContentView()
}
