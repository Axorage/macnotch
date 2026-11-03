import Foundation

enum PomodoroPhase: String, Codable, CaseIterable {
    case work, shortBreak, longBreak

    var title: String {
        switch self {
        case .work: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }

    var symbolName: String {
        switch self {
        case .work: return "timer"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "figure.walk"
        }
    }
}
