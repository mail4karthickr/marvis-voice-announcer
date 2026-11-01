import Foundation

public enum MarvisError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
