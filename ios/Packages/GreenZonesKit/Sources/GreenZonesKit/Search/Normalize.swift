import Foundation

/// EINE Normalisierung fuer Index UND Query — Port von
/// `client/src/lib/search/normalize.ts`.
///
/// Sie steht an drei Stellen im Weg eines Treffers: die Pipeline schreibt
/// `norm_name`/`norm_context` damit, die Query laeuft hier durch, und der
/// Merge-Dedupe vergleicht Namen damit. Weichen zwei dieser Stellen ab, findet
/// der Index nur noch, was zufaellig identisch getippt wurde.
public enum Normalize {
    /// lowercase · trim · ä→ae ö→oe ü→ue ß→ss · restliche Diakritika weg (é→e).
    ///
    /// Die Reihenfolge ist bindend: erst NFC — sonst kommt ein zerlegtes „ü"
    /// (u + U+0308) nie bei der Umlaut-Abbildung an und wuerde im letzten
    /// Schritt zu „u" statt „ue". „Osnabrück" waere dann je nach Tastatur zwei
    /// verschiedene Orte.
    public static func apply(_ input: String) -> String {
        var mapped = String()
        mapped.reserveCapacity(input.count + 4)
        let folded = input.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for character in folded {
            switch character {
            case "ä": mapped += "ae"
            case "ö": mapped += "oe"
            case "ü": mapped += "ue"
            case "ß": mapped += "ss"
            default: mapped.append(character)
            }
        }
        let decomposed = mapped.decomposedStringWithCanonicalMapping
        var stripped = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            stripped.append(scalar)
        }
        return String(stripped).precomposedStringWithCanonicalMapping
    }

    /// Query → Suchterme. Getrennt wird an allem, was kein Buchstabe und keine
    /// Ziffer ist — dieselbe Grenze zieht der `unicode61`-Tokenizer im Index,
    /// sonst suchte die App nach Zeichenfolgen, die dort nie als Term stehen.
    public static func terms(_ input: String) -> [String] {
        apply(input)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
