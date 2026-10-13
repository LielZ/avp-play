import Foundation
import Security

/// Apples Zwischenzertifikat für Entwicklerzertifikate („Apple Worldwide Developer Relations Certification
/// Authority“, in Generationen G1 … G6). Ein „Apple Development“-Zertifikat ist von einer dieser Generationen
/// ausgestellt. Fehlt sie auf dem Mac, kann `codesign` die Kette bis zu Apples Wurzel nicht bilden: Die Signatur
/// scheitert, ohne dass macOS etwas fragt, und `security find-identity -v` führt den Schlüssel gar nicht erst als
/// gültig – die Probe-Signatur (`SigningWarmUp`) hielt den Mac dann für einen ohne Schlüssel, und der Bau brach
/// später mit einer Meldung ab, die nichts davon sagt.
///
/// Xcode bringt das Zertifikat mit, sobald es das Konto einmal geladen hat; ein Mac, auf dem der Schlüssel aus
/// einer Sicherung oder von einem anderen Mac stammt, hat es nicht unbedingt. Hier wird der Fall erkannt und das
/// Zertifikat von Apple geholt, geprüft und in den Anmelde-Schlüsselbund gelegt. Ein Zertifikat ist kein
/// Schlüssel: macOS fragt dabei nichts.
///
/// (Beobachtung und Vorgehen aus dem Projekt Glovebox, github.com/glovebox-vr/glovebox, Issue 4 und
/// installer/App/Glovebox/SigningKey.swift, MIT-Lizenz.)
public enum AppleIntermediate {
    public static let issuerName = "Apple Worldwide Developer Relations Certification Authority"

    /// Die Generation („G3“) aus dem Aussteller eines Zertifikats, wenn Apples Entwickler-Zwischenzertifikat es
    /// ausgestellt hat.
    static func generation(issuerCommonName cn: String?, unit ou: String?) -> String? {
        guard cn == issuerName, let ou, isGeneration(ou) else { return nil }
        return ou
    }

    /// Wo Apple diese Generation veröffentlicht.
    static func url(generation g: String) -> URL? {
        isGeneration(g) ? URL(string: "https://www.apple.com/certificateauthority/AppleWWDRCA\(g).cer") : nil
    }

    private static func isGeneration(_ s: String) -> Bool {
        s.range(of: #"^G[0-9]{1,2}$"#, options: .regularExpression) != nil
    }

    /// Ein „Apple Development“-Zertifikat dieses Teams, zu dem ein Schlüssel im Schlüsselbund liegt, das heute gilt
    /// und dessen Aussteller auf diesem Mac fehlt: das Zertifikat und die fehlende Generation. Liest nur
    /// Zertifikate, ohne Netz; `nil`, wenn es keines gibt. Abgelaufene zählen nicht – ein Schlüsselbund sammelt
    /// sie über die Jahre (auf dem Mac, an dem das entstand, neun neben dem einen gültigen), und für sie gibt es
    /// nichts zu richten.
    static func missing(team: String, now: Date = Date()) -> (leaf: SecCertificate, generation: String)? {
        var found: CFTypeRef?
        guard SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                   kSecReturnRef as String: true] as CFDictionary, &found) == errSecSuccess,
              let all = found as? [Any] else { return nil }
        for item in all {
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(item as! SecIdentity, &cert) == errSecSuccess, let cert else { continue }
            let subject = name(of: cert, kSecOIDX509V1SubjectName)
            guard subject.cn?.hasPrefix("Apple Development") == true, subject.ou == team else { continue }
            let issuer = name(of: cert, kSecOIDX509V1IssuerName)
            guard let generation = generation(issuerCommonName: issuer.cn, unit: issuer.ou), valid(cert, at: now) else { continue }
            if chain([cert]).certificates.count < 2 { return (cert, generation) }
        }
        return nil
    }

    /// Holt die Generation bei Apple, prüft mit der Vertrauensprüfung von macOS (ohne Netz), dass sie das
    /// Zertifikat ausgestellt hat und zu Apples Wurzel führt, und legt sie in den Anmelde-Schlüsselbund – über den
    /// Pfad, weil ein Mac ohne Standard-Schlüsselbund per Doppelklick nichts aufnehmen kann.
    /// - Returns: was geschehen ist, für das Protokoll
    @discardableResult
    static func add(_ generation: String, for leaf: SecCertificate, timeout: TimeInterval = 30) throws -> String {
        guard let url = url(generation: generation) else { throw problem(generation, L("no such generation", "diese Generation gibt es nicht")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var answer: (Data?, URLResponse?, Error?)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            answer = (data, response, error)
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 5) == .success, let data = answer.0,
              (answer.1 as? HTTPURLResponse)?.statusCode == 200 else {
            throw problem(generation, L("could not be downloaded from \(url.absoluteString)", "ließ sich nicht von \(url.absoluteString) laden")
                          + (answer.2.map { ": \($0.localizedDescription)" } ?? ""))
        }
        guard issued(leaf, by: data) else {
            throw problem(generation, L("what \(url.absoluteString) delivers does not lead from the signing certificate to Apple's root",
                                        "was \(url.absoluteString) liefert, führt nicht vom Signierzertifikat zu Apples Wurzel"))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-AppleWWDRCA\(generation)-\(UUID().uuidString).cer")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let login = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
        let added = SigningWarmUp.run(["/usr/bin/security", "add-certificates", "-k", login, file.path], timeout: 30)
        guard chain([leaf]).certificates.count >= 2 else {
            throw problem(generation, L("could not be added to the login keychain", "ließ sich nicht in den Anmelde-Schlüsselbund legen")
                          + ": security \(added.status.map(String.init) ?? "–") \(added.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return L("Apple's \(generation) intermediate certificate was missing on this Mac; fetched from Apple, checked and added to the login keychain.",
                 "Apples Zwischenzertifikat \(generation) fehlte auf diesem Mac; von Apple geholt, geprüft und in den Anmelde-Schlüsselbund gelegt.")
    }

    /// Ob diese Daten ein Zertifikat sind, das `leaf` ausgestellt hat und selbst zu Apples Wurzel führt – nach
    /// der Vertrauensprüfung von macOS, ohne Netz. Erst danach kommt etwas in den Schlüsselbund.
    static func issued(_ leaf: SecCertificate, by data: Data) -> Bool {
        guard let intermediate = SecCertificateCreateWithData(nil, data as CFData) else { return false }
        let checked = chain([leaf, intermediate])
        return checked.trusted && checked.certificates.count >= 3
            && SecCertificateCopyData(checked.certificates[1]) as Data == data
            && checked.certificates.last.flatMap({ SecCertificateCopySubjectSummary($0) as String? }) == "Apple Root CA"
    }

    private static func problem(_ generation: String, _ what: String) -> ToolchainError {
        .signingBlocked(L("Apple's \(generation) intermediate certificate is missing on this Mac and \(what). "
                          + "Opening Xcode › Settings › Accounts and selecting your account installs it.",
                          "Apples Zwischenzertifikat \(generation) fehlt auf diesem Mac und \(what). "
                          + "Xcode › Einstellungen › Accounts öffnen und das Konto anklicken installiert es."))
    }

    /// Ob das Zertifikat zu diesem Zeitpunkt gilt (zwischen „gültig ab“ und „gültig bis“).
    static func valid(_ cert: SecCertificate, at now: Date) -> Bool {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        guard let values = SecCertificateCopyValues(cert, keys as CFArray, nil) as? [String: [String: Any]] else { return false }
        func date(_ key: CFString) -> Date? {
            (values[key as String]?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        guard let from = date(kSecOIDX509V1ValidityNotBefore), let until = date(kSecOIDX509V1ValidityNotAfter) else { return false }
        return from <= now && now < until
    }

    /// Die Kette, die macOS aus diesen Zertifikaten und dem, was auf dem Mac liegt, bilden kann – ohne Netz.
    static func chain(_ certs: [SecCertificate]) -> (certificates: [SecCertificate], trusted: Bool) {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust
        else { return ([], false) }
        SecTrustSetNetworkFetchAllowed(trust, false)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        return ((SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [], trusted)
    }

    /// Name und Organisationseinheit aus dem Inhaber oder dem Aussteller eines Zertifikats.
    static func name(of cert: SecCertificate, _ which: CFString) -> (cn: String?, ou: String?) {
        guard let values = SecCertificateCopyValues(cert, [which] as CFArray, nil) as? [String: [String: Any]],
              let parts = values[which as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] else { return (nil, nil) }
        func field(_ oid: CFString) -> String? {
            parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid as String }?[kSecPropertyKeyValue as String] as? String
        }
        return (field(kSecOIDCommonName), field(kSecOIDOrganizationalUnitName))
    }
}
