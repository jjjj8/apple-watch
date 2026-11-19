import SwiftUI

struct ReportView: View {
    let night: NightReport
    let onDelete: () -> Void
    @EnvironmentObject private var player: Player
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section("概况") {
                row("开始", Format.clock(night.start))
                row("结束", Format.clock(night.end))
                row("时长", Format.duration(night.duration))
                if let saver = night.saverMode {
                    row("模式", saver ? "省电" : "完整录音")
                }
                if !night.stoppedByUser {
                    Text("没有正常停止：App 可能被系统关闭了。结束时间是最后一条记录的时间。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("电量") {
                row("开始", Format.percent(night.batteryStart))
                row("结束", Format.percent(night.batteryEnd))
                row("用掉", Format.percent(night.batteryUsed))
                if let perHour = night.batteryPerHour {
                    row("每小时", String(format: "%.1f%%", perHour))
                }
            }

            Section("系统有没有打断") {
                row("打断次数", "\(night.interruptions)")
                row("录音断档", "\(night.gaps.count) 次")
                row("缺失时长", Format.duration(night.missingSeconds))
                ForEach(night.gaps) { gap in
                    Text("\(Format.clock(gap.time)) 断了 \(Format.duration(gap.value))")
                        .font(.footnote)
                }
            }

            Section {
                row("检测到", "\(night.snoreHits) 次")
                row("鼾声片段", "\(night.episodes.count) 段")
                row("约", String(format: "%.0f 分钟", night.snoreMinutes))
                ForEach(night.episodes) { ep in
                    Button {
                        if player.playingID == ep.id {
                            player.stop()
                        } else {
                            player.play(night: night, at: ep.start, id: ep.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: player.playingID == ep.id ? "stop.circle.fill" : "play.circle")
                            VStack(alignment: .leading) {
                                Text(Format.clock(ep.start))
                                Text("\(ep.hits) 次 · 最高 \(Int(ep.maxConfidence * 100))%")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let err = player.error {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("打鼾")
            } footer: {
                Text("点一段可以在手表上播放那一刻的录音，听听识别得对不对。")
            }

            if !night.errors.isEmpty {
                Section("出错信息") {
                    ForEach(night.errors) { e in
                        Text("\(Format.clock(e.time)) \(e.note)").font(.footnote)
                    }
                }
            }

            Section {
                row("占用空间", String(format: "%.1f MB", night.folderSizeMB))
                row("音频文件", "\(night.segments.count) 个")
                row("大声次数", "\(night.loudCount)")
                Button("删除这晚的记录", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("仅用于测试，不是医疗诊断。")
            }
        }
        .navigationTitle(Format.dayAndTime(night.start))
        .onDisappear { player.stop() }
        .confirmationDialog("删除这晚的录音和记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
