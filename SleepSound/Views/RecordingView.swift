import SwiftUI

struct RecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var confirmStop = false
    let onStopped: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let start = recorder.startDate {
                    Text(start, style: .timer)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Text("正在录音").foregroundStyle(.red)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("鼾声")
                        Text(recorder.classifierAvailable ? "\(recorder.snoreCount) 次" : "识别不可用")
                    }
                    GridRow {
                        Text("音量")
                        Text(String(format: "%.0f dB", recorder.levelDB))
                    }
                    GridRow {
                        Text("被打断")
                        Text("\(recorder.interruptionCount) 次 / 断档 \(recorder.gapCount)")
                    }
                }
                .font(.footnote)

                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .padding(.top, 6)
            }
        }
        .confirmationDialog("结束今晚的录音？", isPresented: $confirmStop) {
            Button("结束并查看报告", role: .destructive) {
                recorder.stop()
                onStopped()
            }
            Button("继续录音", role: .cancel) {}
        }
    }
}
