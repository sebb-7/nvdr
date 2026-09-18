import Foundation

/// Derives a conservative text fallback from SSML when a receiving device
/// cannot render the SSML itself. This adds no semantic labels or roles; it
/// only keeps character data already present in the provider request.
enum RemoteSpeechPlainTextExtractor {
    static func extract(from ssml: String) -> String? {
        let collector = CharacterCollector()
        guard let data = ssml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private final class CharacterCollector: NSObject, XMLParserDelegate {
        var text = ""

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text.append(string)
        }
    }
}
