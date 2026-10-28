import AVFoundation
import NaturalLanguage
import Observation

@MainActor @Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// The text currently being read, so its button can show a stop state.
    private(set) var speakingText: String?

    var autoSpeak = UserDefaults.standard.bool(forKey: "autoSpeak") {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "autoSpeak") }
    }
    var slow = UserDefaults.standard.bool(forKey: "slowSpeech") {
        didSet { UserDefaults.standard.set(slow, forKey: "slowSpeech") }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads `text` aloud, or stops if that text is already playing.
    func toggle(_ text: String, language: String?) {
        let wasSpeaking = speakingText == text
        stop()
        if !wasSpeaking { speak(text, language: language) }
    }

    func speak(_ text: String, language: String?) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Speaker.bestVoice(for: language ?? Speaker.guessLanguage(of: text))
        utterance.rate = slow ? 0.36 : AVSpeechUtteranceDefaultSpeechRate
        speakingText = text
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingText = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in if self.speakingText == text { self.speakingText = nil } }
    }

    // MARK: Voices

    /// Highest-quality installed voice for a BCP-47 code like "pt-PT", falling back to the bare language.
    static func bestVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        guard let language else { return nil }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let exact = voices.filter { $0.language == language }
        let candidates = exact.isEmpty ? voices.filter { $0.language.hasPrefix(base) } : exact
        let fallback = AVSpeechSynthesisVoice(language: language)
        guard let best = candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else { return fallback }
        // Keep the system's default voice unless a better-quality one is installed.
        return fallback.map { $0.quality.rawValue >= best.quality.rawValue ? $0 : best } ?? best
    }

    /// Best guess for cards without a known language. Portuguese defaults to European Portuguese.
    static func guessLanguage(of text: String) -> String? {
        guard let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return nil }
        return code == "pt" ? "pt-PT" : code
    }
}
