import Foundation

/// Which vendor's API the AI features talk to.
///
/// The user picks one in Settings and it applies to both features. The choice is deliberately
/// **device-local** rather than synced through iCloud, because the API key it depends on is
/// device-local: a synced provider would flip an iPad to a vendor whose key only ever existed on
/// the iPhone, leaving scanning switched on with no usable credential. See ``AISettings``.
enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    /// Resolve a stored raw value. Never force-unwrap something that round-trips through storage:
    /// a value written by a newer build, or by a build that offered a provider this one does not
    /// (`"google"`, from installs that picked Gemini), lands on the provider this app starts with
    /// rather than crashing. The credential such a selection left behind is a separate problem —
    /// see ``AISettings/purgeRetiredProviderData()``, which is what deletes it.
    static func named(_ raw: String?) -> AIProvider {
        guard let raw, let provider = AIProvider(rawValue: raw) else { return .anthropic }
        return provider
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    /// Keychain account for this provider's key. Each provider keeps its own, so switching back
    /// and forth never costs the user a re-paste.
    ///
    /// The Anthropic account string is `anthropic.apiKey` because that is what shipped — changing
    /// it would strand every existing user's key. See the warning in ``KeychainStore``.
    var keychainAccount: String {
        switch self {
        case .anthropic: return "anthropic.apiKey"
        case .openai: return "openai.apiKey"
        }
    }

    var keyFieldLabel: String {
        switch self {
        case .anthropic: return "Anthropic API Key"
        case .openai: return "OpenAI API Key"
        }
    }

    /// Where the user creates a key, as the Settings footer prints it: a host and path, not a URL.
    var apiKeyPageAddress: String {
        switch self {
        case .anthropic: return "platform.claude.com/settings/keys"
        case .openai: return "platform.openai.com/api-keys"
        }
    }

    var wire: AIWireFormat {
        switch self {
        case .anthropic: return AnthropicWire()
        case .openai: return OpenAIWire()
        }
    }
}
