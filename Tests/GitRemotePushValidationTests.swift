import Foundation
import Testing
@testable import MoeKit

@Suite("Exact HTTPS remote push validation")
struct GitRemotePushValidationTests {
    @Test("Ordinary explicit HTTPS hosts and repository paths remain exact", arguments: [
        "https://github.com/cosZone/MoeKit.git", "https://git.example.com/team/subgroup/project.git",
        "https://code-2.example.test/team_a/repo.name"
    ])
    func acceptedEndpoints(_ value: String) throws {
        let endpoint = try GitRemoteEndpoint(value)
        #expect(endpoint.url == value)
        #expect(value == "https://" + endpoint.host + "/" + endpoint.path)
    }

    @Test("Ambiguous schemes, authority, escapes and host spoofing fail closed", arguments: [
        "", "http://github.com/a/b", "ssh://github.com/a/b", "git@github.com:a/b", "file:///tmp/a",
        "https://user@github.com/a/b", "https://github.com@evil.test/a/b", "https://github.com:443/a/b",
        "https://GitHub.com/a/b", "https://github.com./a/b", "https://github..com/a/b", "https://-git.example/a/b",
        "https://git-.example/a/b", "https://xn--git.example/a/b", "https://gіthub.com/a/b", "https://127.0.0.1/a/b",
        "https://localhost/a/b", "https://example.local/a/b", "https://example.internal/a/b",
        "https://github.com", "https://github.com/", "https://github.com/a//b", "https://github.com/a/../b",
        "https://github.com/a/./b", "https://github.com/-a/b", "https://github.com/a/b/", "https://github.com/a%2fb",
        "https://github.com/a/b?token=x", "https://github.com/a/b#x", "https://github.com/a/b\n",
        "https://github.com/a b", "https://github.com/a;b", "https://github.com/a$(id)", "https://github.com/a`id`",
        "https://github.com/a\\b", "https://github.com/a\u{0}b"
    ])
    func rejectedEndpoints(_ value: String) {
        #expect(throws: GitRemotePushFailure.endpoint) { try GitRemoteEndpoint(value) }
    }

    @Test("Only a single ordinary branch is converted to an exact heads ref")
    func exactBranchReference() throws {
        #expect(try GitRemoteEndpoint.ref(branch: "main") == "refs/heads/main")
        #expect(try GitRemoteEndpoint.ref(branch: "release/1.2_x") == "refs/heads/release/1.2_x")
        for value in ["", "+main", "-main", "/main", "a//b", "a/", ".a", "a.", "a.lock", "a/thing.lock",
                      "a..b", "a:b", "a*b", "a@{1}", "a~1", "a^", "a b", "a\nb", "a\\b", "日本語",
                      String(repeating: "a", count: 241)] {
            #expect(throws: GitRemotePushFailure.reference) { try GitRemoteEndpoint.ref(branch: value) }
        }
    }

    @Test("Remote advertisements must contain one exact ref and lowercase nonzero SHA-1")
    func exactAdvertisement() throws {
        let oid = String(repeating: "a", count: 40), ref = "refs/heads/main"
        let valid = oid + "\t" + ref + "\n"
        #expect(try GitRemoteTransportSession.parseAdvertisement(Data(valid.utf8), ref: ref) == oid)
        for value in [valid + valid, valid + "\n", String(valid.dropLast()), valid.replacingOccurrences(of: "\n", with: "\r\n"),
                      valid.replacingOccurrences(of: ref, with: "refs/heads/other"), valid.replacingOccurrences(of: oid, with: oid.uppercased()),
                      valid.replacingOccurrences(of: oid, with: String(repeating: "0", count: 40)),
                      valid.replacingOccurrences(of: oid, with: "HEAD"), valid.replacingOccurrences(of: "\t", with: " "),
                      "", String(repeating: "x", count: 4097)] {
            #expect(throws: GitRemotePushFailure.inspection) { try GitRemoteTransportSession.parseAdvertisement(Data(value.utf8), ref: ref) }
        }
        #expect(throws: GitRemotePushFailure.inspection) { try GitRemoteTransportSession.parseAdvertisement(Data([0xff]), ref: ref) }
    }
}
