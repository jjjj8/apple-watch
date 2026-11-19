import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [String] = []
    @State private var nights: [NightReport] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if recorder.isRecording {
                    RecordingView(onStopped: showLatest)
                } else {
                    homeList
                }
            }
            .navigationTitle("睡眠录音")
            .navigationDestination(for: String.self) { id in
                if let night = nights.first(where: { $0.id == id }) {
                    ReportView(night: night, onDelete: {
                        SessionStore.delete(night)
                        path.removeAll()
                        reload()
                    })
                } else {
                    Text("记录不存在")
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            recorder.note("scene phase: \(phase)")
            if phase == .active, !recorder.isRecording { reload() }
        }
        .alert("没有麦克风权限", isPresented: $recorder.permissionDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请在 iPhone 的 Watch App 或手表“设置 > 隐私与安全性 > 麦克风”里允许“睡眠录音”。")
        }
    }

    private var homeList: some View {
        List {
            Section {
                Button {
                    recorder.start()
                } label: {
                    Label("开始整晚录音", systemImage: "moon.zzz.fill")
                        .font(.headline)
                }
                .listItemTint(.indigo)
                Toggle("省电模式", isOn: $recorder.saverMode)
                if let err = recorder.lastError {
                    Text("启动失败：\(err)").font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text(recorder.saverMode
                     ? "省电模式：只在有声音时识别和保存录音。睡前点开始，起床后点停止。仅用于测试，不是医疗诊断。"
                     : "完整录音：整晚都保存，更耗电。睡前点开始，起床后点停止。仅用于测试，不是医疗诊断。")
            }

            if !nights.isEmpty {
                Section("历史记录") {
                    ForEach(nights) { night in
                        NavigationLink(value: night.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.dayAndTime(night.start))
                                Text("\(Format.duration(night.duration)) · 鼾声 \(night.episodes.count) 段")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        nights = SessionStore.allNights()
    }

    private func showLatest() {
        reload()
        if let first = nights.first { path = [first.id] }
    }
}
