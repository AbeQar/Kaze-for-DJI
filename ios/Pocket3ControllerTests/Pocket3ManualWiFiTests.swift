import Testing
@testable import Pocket3Controller

@MainActor
struct Pocket3ManualWiFiTests {
    @Test func manualJoinRequiresControlHandshakeAndSupportsRetry() {
        let wifi = Pocket3WiFiManager()
        wifi.waitForManualJoin(ssid: "OsmoPocket3-test", password: "camera-test")
        #expect(wifi.needsManualJoin)
        #expect(!wifi.isBusy)
        #expect(!wifi.isJoined)
        wifi.beginManualControlConnection()
        #expect(!wifi.needsManualJoin)
        #expect(!wifi.isJoined)
        wifi.waitForManualJoin(ssid: "OsmoPocket3-test", password: "camera-test")
        #expect(wifi.needsManualJoin)
        wifi.beginManualControlConnection()
        wifi.confirmManualControlConnection()
        #expect(wifi.isJoined)
        #expect(!wifi.needsManualJoin)
        var didDisconnect = false
        wifi.disconnect { didDisconnect = true }
        #expect(didDisconnect)
        #expect(!wifi.isJoined)
        #expect(!wifi.isUsingManualNetwork)
        #expect(wifi.manualPassword.isEmpty)
    }

    @Test func missingSimulatorProfileOffersManualJoinWithoutCallingHotspotAPI() {
        #expect(!Pocket3WiFiManager.profileAllowsHotspotConfiguration)
        let wifi = Pocket3WiFiManager()
        var joined: Bool?
        wifi.join(ssid: "OsmoPocket3-test", passphrase: "camera-test") { joined = $0 }
        #expect(joined == false)
        #expect(wifi.needsManualJoin)
        #expect(!wifi.isBusy)
        #expect(!wifi.isJoined)
    }

    @Test func cancellingManualJoinDoesNotClaimNetworkJoined() {
        let wifi = Pocket3WiFiManager()
        wifi.waitForManualJoin(ssid: "OsmoPocket3-test", password: "camera-test")
        wifi.disconnect()
        wifi.confirmManualControlConnection()
        #expect(!wifi.needsManualJoin)
        #expect(!wifi.isJoined)
        #expect(wifi.manualPassword.isEmpty)
    }
}
