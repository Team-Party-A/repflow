import SwiftUI

struct ContentView: View {
    @StateObject private var training = ManualTraining()
    @ObservedObject var transfer: RecordingTransfer
    @State private var exerciseID = ""
    @State private var confirmDiscard = false
    @State private var confirmEnd = false

    init(transfer: RecordingTransfer = .shared) { self.transfer = transfer }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !training.errorMessage.isEmpty {
                        Label(training.errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Color("red"))
                    }
                    if !training.storageReady {
                        action("重试读取", icon: "arrow.clockwise", primary: true) { training.reload() }
                    } else {
                        phaseContent
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
            .background(Color("ground"))
            .foregroundStyle(Color("text"))
            .navigationTitle("RepFlow")
            .confirmationDialog("放弃本组？已保存的组会保留。", isPresented: $confirmDiscard) {
                Button("放弃本组", role: .destructive) { training.discardSet() }
                Button("保留本组", role: .cancel) {}
            }
            .confirmationDialog(
                training.current?.candidate == nil ? "结束本次训练？" : "本组尚未保存",
                isPresented: $confirmEnd
            ) {
                if training.current?.candidate != nil {
                    Button("放弃本组并结束训练", role: .destructive) {
                        training.finishWorkout(discardCandidate: true)
                    }
                    Button(training.phase == .active ? "继续本组" : "返回核对", role: .cancel) {}
                } else {
                    Button("结束训练") { training.finishWorkout() }
                    Button("继续训练", role: .cancel) {}
                }
            } message: {
                Text("已确认的组保留在手表，不发送到手机。")
            }
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch training.phase {
        case .choose, .rest:
            if training.phase == .rest, let workout = training.current {
                Label("组间 · 已保存 \(workout.sets.count) 组", systemImage: "checkmark.circle")
                Text("动作总次数 \(workout.totalReps)").font(.footnote)
            }
            Picker("动作", selection: $exerciseID) {
                Text("请选择动作").tag("")
                ForEach(ExerciseCatalog.all) { Text($0.displayName).tag($0.id) }
            }
            .pickerStyle(.navigationLink)
            action(
                "开始第 \((training.current?.sets.count ?? 0) + 1) 组", icon: "play.fill",
                primary: true, enabled: ExerciseCatalog.exercise(id: exerciseID) != nil
            ) { training.startSet(exerciseID: exerciseID) }
            localNotice
            if training.phase == .rest { endWorkoutButton }
            if training.phase == .choose {
                NavigationLink("已保存训练（\(training.snapshot.workouts.count)）") {
                    List(training.snapshot.workouts.reversed()) { workout in
                        NavigationLink {
                            ScrollView { WorkoutSummary(workout: workout).padding(8) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(workout.startedAt, style: .date)
                                Text("\(workout.sets.count) 组 · \(workout.totalReps) 次")
                            }
                        }
                    }.navigationTitle("仅保存在手表")
                }
                NavigationLink("传感器录制") { RecordingView(transfer: transfer) }
            }
        case .active:
            if let candidate = training.current?.candidate {
                Text(exerciseName(candidate.exerciseID)).font(.headline)
                Text("第 \((training.current?.sets.count ?? 0) + 1) 组 · 手动训练").font(.footnote)
                Text("0 次").font(.system(size: 64, weight: .heavy)).fontWidth(.compressed)
                    .accessibilityLabel("未录入次数")
                Text("未接入自动计次\n结束本组后手动填写次数")
                    .font(.footnote).foregroundStyle(Color("text2"))
                HStack {
                    Text("已用时间")
                    Text(candidate.startedAt, style: .timer).monospacedDigit()
                }.font(.footnote)
                action("结束本组", icon: "stop.fill") { training.endSet() }
                endWorkoutButton
            }
        case .review:
            if let candidate = training.current?.candidate {
                Text(exerciseName(candidate.exerciseID)).font(.headline)
                Label("待核对 · 手动次数", systemImage: "pencil")
                    .font(.footnote).foregroundStyle(Color("amber"))
                Text("\(candidate.reps) 次").font(.system(size: 48, weight: .heavy))
                    .fontWidth(.compressed).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityLabel("最终次数 \(candidate.reps) 次")
                HStack(spacing: 16) {
                    action("减 1 次", icon: "minus", enabled: candidate.reps > 0, symbolOnly: true) {
                        training.adjustReps(by: -1)
                    }
                    action("加 1 次", icon: "plus", enabled: candidate.reps < 9999, symbolOnly: true)
                    {
                        training.adjustReps(by: 1)
                    }
                }
                Text(candidate.reps == 0 ? "至少填写 1 次，或放弃本组" : "未接入自动计次，无原估计值")
                    .font(.footnote).foregroundStyle(Color("text2"))
                action("确认并保存", icon: "checkmark", primary: true, enabled: candidate.reps > 0) {
                    training.saveSet()
                }
                Button("放弃本组", role: .destructive) { confirmDiscard = true }
                    .foregroundStyle(Color("red")).buttonStyle(.plain).frame(minHeight: 44)
                endWorkoutButton
            }
        case .summary:
            if let workout = training.current {
                WorkoutSummary(workout: workout)
                action("开始新训练", icon: "play.fill", primary: true) { training.prepareNewWorkout() }
                NavigationLink("传感器录制") { RecordingView(transfer: transfer) }
            }
        }
    }

    private var localNotice: some View {
        Label("手动记录 · 未接入自动计次\n仅保存在手表，不发送到手机", systemImage: "applewatch")
            .font(.footnote).foregroundStyle(Color("text2"))
    }

    private var endWorkoutButton: some View {
        Button("结束训练") { confirmEnd = true }
            .buttonStyle(.plain).foregroundStyle(Color("text2")).frame(minHeight: 44)
    }

    private func action(
        _ title: String, icon: String, primary: Bool = false, enabled: Bool = true,
        symbolOnly: Bool = false, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Group {
                if symbolOnly { Image(systemName: icon) } else { Label(title, systemImage: icon) }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 4)
            .background(primary ? Color("volt") : Color("raised"), in: Capsule())
            .foregroundStyle(primary ? Color.black : Color("text"))
        }
        .buttonStyle(.plain).accessibilityLabel(title).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

private func exerciseName(_ id: String) -> String {
    ExerciseCatalog.exercise(id: id)?.displayName ?? "未知动作（\(id)），请更新 App"
}

private struct WorkoutSummary: View {
    let workout: ManualWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("训练结束").font(.headline)
            Text(workout.startedAt, style: .date).font(.footnote)
            Text("\(workout.sets.count) 组 · \(workout.totalReps) 次").font(.title3.bold())
            Label("仅保存在手表，不发送到手机", systemImage: "applewatch").font(.footnote)
            if workout.sets.isEmpty { Text("本次没有保存任何组。").font(.footnote) }
            ForEach(Array(workout.sets.enumerated()), id: \.element.id) { index, set in
                VStack(alignment: .leading, spacing: 4) {
                    Text("第 \(index + 1) 组 · \(exerciseName(set.exerciseID))")
                    Text("\(set.reps) 次 · 手动").font(.headline)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color("surface"), in: RoundedRectangle(cornerRadius: 12))
            }
        }.foregroundStyle(Color("text"))
    }
}

#Preview { ContentView() }
