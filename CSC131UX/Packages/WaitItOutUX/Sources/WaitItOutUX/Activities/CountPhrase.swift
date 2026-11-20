import Foundation

/// Builds "1 activity" or "2 activities" style phrases for status text.
enum CountPhrase {
    static func make(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
