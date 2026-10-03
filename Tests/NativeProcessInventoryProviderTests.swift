import Darwin
import Foundation
import Testing
@testable import MoeKit

/// These fixtures do not enumerate real processes, open sockets, launch children,
/// inspect argv/environment, or send signals on the test runner.
struct NativeProcessInventoryProviderTests {
    @Test("Native strings require a terminator, valid UTF-8 and a nonempty value")
    func boundedStrings() {
        #expect(NativeProcessInventoryParsing.executablePathCapacity == 4 * Int(PATH_MAX))
        #expect(decode(Array("/tmp/project".utf8) + [0, 65]) == "/tmp/project")
        #expect(decode(Array("/tmp/项目".utf8) + [0]) == "/tmp/项目")
        #expect(decode([]) == nil)
        #expect(decode([0]) == nil)
        #expect(decode([65, 66]) == nil)
        #expect(decode([0xFF, 0]) == nil)
    }

    @Test("An IPv4 listener uses only its local address and network-order port")
    func ipv4Listener() {
        let fixture = ipv4Socket(port: 8_080)
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .listener(
            ListeningPort(port: 8_080, address: "127.0.0.1", transport: "TCP")
        ))
    }

    @Test("An IPv6 wildcard listener retains its local address")
    func ipv6Listener() {
        var fixture = ipv4Socket(port: 4_433)
        fixture.psi.soi_family = AF_INET6
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV6)
        // A zero-initialized IPv6 address is the unspecified local address.
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_6 = in6_addr()
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .listener(
            ListeningPort(port: 4_433, address: "::", transport: "TCP")
        ))
    }

    @Test("Connected TCP sockets are not reported as listeners")
    func connectedTCPIsExcluded() {
        var fixture = ipv4Socket(port: 8_080)
        fixture.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .notListener)
    }

    @Test("UDP, generic sockets and non-stream sockets are excluded")
    func nonTCPIsExcluded() {
        var fixture = ipv4Socket(port: 5_353)
        fixture.psi.soi_protocol = IPPROTO_UDP
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .notListener)
        fixture = ipv4Socket(port: 5_353)
        fixture.psi.soi_kind = Int32(SOCKINFO_GENERIC)
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .notListener)
        fixture = ipv4Socket(port: 5_353)
        fixture.psi.soi_type = SOCK_DGRAM
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .notListener)
    }

    @Test("Malformed local listener metadata remains unknown")
    func malformedListenerIsUnknown() {
        var fixture = ipv4Socket(port: 8_080)
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = 0
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .unavailable)
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = 65_536
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .unavailable)
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = -1
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .unavailable)
        fixture = ipv4Socket(port: 8_080)
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = 0
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .unavailable)
        fixture = ipv4Socket(port: 8_080)
        fixture.psi.soi_family = AF_UNIX
        #expect(NativeProcessInventoryParsing.tcpListener(fixture) == .unavailable)
    }

    @Test("Invalid budgets fail before any native process enumeration")
    func invalidBudgets() async {
        var fixtures: [ProcessScanOptions] = []
        var options = ProcessScanOptions()
        options.maximumProcesses = 0
        fixtures.append(options)
        options = ProcessScanOptions()
        options.maximumProcesses = Int.max
        fixtures.append(options)
        options = ProcessScanOptions()
        options.maximumFileDescriptorsPerProcess = 0
        fixtures.append(options)
        options = ProcessScanOptions()
        options.maximumFileDescriptorsPerProcess = Int.max
        fixtures.append(options)
        for duration in [0.0, -1.0, .infinity, .nan, 31.0] {
            options = ProcessScanOptions()
            options.maximumDuration = duration
            fixtures.append(options)
        }
        let provider = NativeProcessInventoryProvider()
        for fixture in fixtures {
            await #expect(throws: NativeProcessInventoryError.self) {
                _ = try await provider.scan(options: fixture)
            }
        }
    }

    private func decode(_ bytes: [UInt8]) -> String? {
        bytes.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString)
    }

    private func ipv4Socket(port: UInt16) -> socket_fdinfo {
        var fixture = socket_fdinfo()
        fixture.psi.soi_kind = Int32(SOCKINFO_TCP)
        fixture.psi.soi_protocol = IPPROTO_TCP
        fixture.psi.soi_type = SOCK_STREAM
        fixture.psi.soi_family = AF_INET
        fixture.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(port.bigEndian)
        var local = in_addr()
        local.s_addr = UInt32(0x7F000001).bigEndian
        fixture.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4 = local
        return fixture
    }
}
