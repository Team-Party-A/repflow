import SwiftData
import SwiftUI

struct TodayView: View {
    let userID: UUID
    let openTraining: () -> Void
    @Query private var workouts: [Workout]
    @AppStorage private var goal: Int
    @State private var recording: Recording?

    private struct Recording: Identifiable {
        let id = UUID()
        let sets: [DraftSet]
    }

    init(userID: UUID, openTraining: @escaping () -> Void) {
        self.userID = userID
        self.openTraining = openTraining
        _goal = AppStorage(wrappedValue: 120, "weeklyMinutes.\(userID.uuidString)")
        _workouts = Query(filter: WorkoutStore.owned(by: userID), sort: WorkoutStore.newestFirst())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        let now = timeline.date
                        VStack(alignment: .leading, spacing: 16) {
                            Text(now.formatted(.dateTime.month().day().weekday(.wide)))
                                .foregroundStyle(Palette.text2)
                            SyncBanner(userID: userID)
                            progress(now: now)
                        }
                    }
                    NutritionDayView(userID: userID)
                    TemplateShelf(userID: userID) { recording = Recording(sets: $0) }
                    if let latest = workouts.first {
                        NavigationLink {
                            WorkoutDetailView(userID: userID, workoutID: latest.workoutID)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("最近一次训练").font(.headline)
                                Text(
                                    latest.startedAt.formatted(date: .abbreviated, time: .shortened)
                                )
                                Text(
                                    "\(latest.exerciseIDs.count) 个动作 · \(latest.sets.count) 组 · \(latest.totalReps) 次"
                                )
                            }.frame(maxWidth: .infinity, alignment: .leading).padding().card()
                        }.buttonStyle(.plain)
                    }
                    Button("开始训练") { recording = Recording(sets: []) }
                        .buttonStyle(PrimaryButtonStyle())
                }.padding(.horizontal, 20).padding(.bottom)
            }
            .pageBackground()
            .navigationTitle("今天")
            .sheet(item: $recording) { draft in
                ManualWorkoutView(userID: userID, initialSets: draft.sets)
            }
        }
    }

    private func progress(now: Date) -> some View {
        let week = TrainingWeek(
            sessions: workouts.map { ($0.startedAt, $0.endedAt) }, now: now, calendar: .current)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 2) {
                ForEach(week.days, id: \.self) { date in
                    let logged = week.trained.contains(date)
                    let today = Calendar.current.isDate(date, inSameDayAs: now)
                    Button(action: openTraining) {
                        VStack {
                            Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption)
                            Text(Calendar.current.component(.day, from: date), format: .number)
                                .font(.subheadline).monospacedDigit().bold(today)
                                .lineLimit(1).minimumScaleFactor(0.65)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(logged ? Palette.volt : Palette.raised))
                                .foregroundStyle(logged ? Color.black : Palette.text)
                                .overlay {
                                    if today { Circle().stroke(Palette.text, lineWidth: 2) }
                                }
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(date.formatted(date: .complete, time: .omitted))，\(logged ? "有训练" : "无训练")"
                        )
                }
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Palette.raised, lineWidth: 5)
                    Circle().trim(
                        from: 0, to: min(1, CGFloat(week.minutes) / CGFloat(max(1, goal)))
                    )
                    .stroke(Palette.volt, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    Image(systemName: "timer")
                }.frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(
                        week.streak > 0
                            ? "连续训练 \(week.streak) 周"
                            : week.trained.isEmpty ? "开始你的第一周" : "本周练一次，重新开始连续记录")
                    Text("本周 \(week.minutes) / \(goal) 分钟").font(.headline)
                    if week.minutes > goal { Text("超出目标 \(week.minutes-goal) 分钟").font(.caption) }
                }
            }
        }.padding().card()
    }
}

struct WeeklyGoalSetting: View {
    @AppStorage private var minutes: Int
    init(userID: UUID) {
        _minutes = AppStorage(wrappedValue: 120, "weeklyMinutes.\(userID.uuidString)")
    }
    var body: some View {
        Stepper("本周时长目标 \(minutes) 分钟", value: $minutes, in: 5...10080, step: 5)
            .padding().card()
    }
}

private struct TemplateShelf: View {
    let userID: UUID
    let start: ([DraftSet]) -> Void
    @Environment(\.modelContext) private var context
    @Query private var templates: [TrainingTemplate]
    @State private var creating = false
    @State private var editing: TrainingTemplate?
    @State private var deletion: TrainingTemplate?
    @State private var error: String?

    init(userID: UUID, start: @escaping ([DraftSet]) -> Void) {
        self.userID = userID
        self.start = start
        _templates = Query(filter: TrainingTemplate.owned(by: userID), sort: \TrainingTemplate.name)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("我的模板").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(templates) { template in
                        let targets = template.orderedTargets
                        let names = targets.map(\.exerciseID).reduce(into: [String]()) {
                            if !$0.contains($1) { $0.append($1) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "dumbbell")
                                Spacer()
                                Menu {
                                    Button("编辑") { editing = template }
                                    Button("删除", role: .destructive) { deletion = template }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("管理\(template.name)")
                            }
                            Button {
                                start(TemplateTarget.prefill(targets))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(template.name).font(.headline)
                                    Text("\(names.count) 个动作").font(.caption)
                                    Text(
                                        names.prefix(2).map(ExerciseName.of).joined(separator: "、")
                                    )
                                    .font(.caption).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }.padding().frame(width: 175).card()
                    }
                    Button {
                        creating = true
                    } label: {
                        Label("新建模板", systemImage: "plus").padding().card()
                    }
                }
            }
        }
        .sheet(isPresented: $creating) { TemplateEditor(userID: userID) }
        .sheet(item: $editing) { TemplateEditor(userID: userID, original: $0) }
        .confirmationDialog(
            "删除模板？",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            presenting: deletion
        ) { item in
            Button("删除模板", role: .destructive) {
                context.delete(item)
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    self.error = error.localizedDescription
                }
            }
        } message: { _ in
            Text("已保存的训练会保留。")
        }
        .alert("删除失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }))
        {
            Button("好") {}
        } message: {
            Text(error ?? "")
        }
    }
}
