import Foundation

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分\(total % 60)秒" }
        return "\(total)秒"
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dayAndTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f%%", value)
    }
}
