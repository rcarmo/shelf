import Foundation

enum ShelfSettings {
    static let contentBaseFontSizeKey = "contentBaseFontSize"
    static let useAppleIntelligenceKey = "useAppleIntelligence"
    static let defaultContentBaseFontSize = 12.0
    static let minimumContentBaseFontSize = 10.0
    static let maximumContentBaseFontSize = 18.0

    static func clampedContentBaseFontSize(_ value: Double) -> Double {
        min(max(value, minimumContentBaseFontSize), maximumContentBaseFontSize)
    }
}
