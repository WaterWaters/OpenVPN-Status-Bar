import XCTest
@testable import VPNStatusBarCore

final class OpenVPNSignatureTests: XCTestCase {
    func testParsesAppleSiliconBuild() {
        let parsed = OpenVPNSignature.parse(
            "OpenVPN 2.6.14 aarch64-apple-darwin25.5.0 [SSL (OpenSSL)] [LZO] [LZ4] [MH/RECVDA] [AEAD]"
        )
        XCTAssertEqual(parsed.version, "2.6.14")
        XCTAssertEqual(parsed.arch, "arm64")
    }

    func testParsesIntelBuild() {
        let parsed = OpenVPNSignature.parse("OpenVPN 2.6.14 x86_64-apple-darwin23.0.0 [SSL (OpenSSL)]")
        XCTAssertEqual(parsed.version, "2.6.14")
        XCTAssertEqual(parsed.arch, "x86_64")
    }

    func testParsesArm64TargetTriple() {
        let parsed = OpenVPNSignature.parse("OpenVPN 2.7.0 arm64-apple-darwin25.0.0 [SSL (OpenSSL)]")
        XCTAssertEqual(parsed.arch, "arm64")
    }

    func testFallsBackToFirstTargetComponent() {
        let parsed = OpenVPNSignature.parse("OpenVPN 2.7.0 riscv64-unknown-linux [SSL]")
        XCTAssertEqual(parsed.arch, "riscv64")
    }

    func testIgnoresNoiseAndMissingSignature() {
        XCTAssertNil(OpenVPNSignature.parse("").version)
        XCTAssertNil(OpenVPNSignature.parse("sudo: a password is required").arch)
    }

    func testSkipsLeadingWarningLines() {
        let output = """
        sudo: unable to resolve host foo
        OpenVPN 2.6.14 aarch64-apple-darwin25.5.0 [SSL (OpenSSL)]
        """
        XCTAssertEqual(OpenVPNSignature.parse(output).version, "2.6.14")
    }
}

final class SudoPolicyTests: XCTestCase {
    private let wrapper = "/usr/local/vpnstatusbar/vpn-run.sh"
    private let stable = "/usr/local/vpnstatusbar/openvpn"

    func testDetectsNoPasswdRuleForPath() {
        let listing = """
        User water may run the following commands on mac:
            (root) NOPASSWD: /usr/local/vpnstatusbar/vpn-run.sh
        """
        XCTAssertTrue(SudoPolicy.hasNoPasswdRule(for: wrapper, in: listing))
        XCTAssertFalse(SudoPolicy.hasNoPasswdRule(for: stable, in: listing))
    }

    func testRequiresNoPasswdKeyword() {
        let listing = "    (root) /usr/local/vpnstatusbar/vpn-run.sh"
        XCTAssertFalse(SudoPolicy.hasNoPasswdRule(for: wrapper, in: listing))
    }

    func testDetectsLegacyOwnRule() {
        let listing = "    (root) NOPASSWD: /usr/local/vpnstatusbar/openvpn"
        XCTAssertTrue(SudoPolicy.hasNoPasswdRule(for: stable, in: listing))
    }

    func testIgnoresForeignRulesWhenReported() {
        let listing = """
        Matching Defaults entries for water on mac:
            env_reset, timestamp_timeout=5
        User water may run the following commands on mac:
            (root) NOPASSWD: /usr/local/vpnstatusbar/vpn-run.sh
        """
        XCTAssertNil(SudoPolicy.firstForeignOpenVPNRule(in: listing, excluding: [stable, wrapper]))
    }

    func testFindsForeignOpenVPNRule() {
        let listing = """
        User water may run the following commands on mac:
            (root) NOPASSWD: /opt/homebrew/sbin/openvpn
            (root) NOPASSWD: /usr/local/vpnstatusbar/vpn-run.sh
        """
        XCTAssertEqual(
            SudoPolicy.firstForeignOpenVPNRule(in: listing, excluding: [stable, wrapper]),
            "/opt/homebrew/sbin/openvpn"
        )
    }

    func testEmptyListingIsSafe() {
        XCTAssertFalse(SudoPolicy.hasNoPasswdRule(for: wrapper, in: ""))
        XCTAssertNil(SudoPolicy.firstForeignOpenVPNRule(in: "", excluding: []))
    }
}

final class ProfileTests: XCTestCase {
    func testParsesServerAddressFromRemoteLine() {
        XCTAssertEqual(
            VPNProfile.parseServerAddress(from: "client\nremote 183.222.16.242 7777 udp\n"),
            "183.222.16.242 7777 udp"
        )
    }

    func testReturnsDashWithoutRemoteLine() {
        XCTAssertEqual(VPNProfile.parseServerAddress(from: "client\ndev tun\n"), "—")
    }
}
