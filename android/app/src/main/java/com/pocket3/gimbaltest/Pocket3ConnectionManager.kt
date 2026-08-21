package com.pocket3.gimbaltest

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import android.os.Looper
import dev.konraditurbe.osmosis.ble.GattClient
import dev.konraditurbe.osmosis.ble.OsmoScanner
import dev.konraditurbe.osmosis.duml.DjiMessage
import dev.konraditurbe.osmosis.duml.OsmoCommands
import dev.konraditurbe.osmosis.net.ApJoiner
import java.util.UUID

/**
 * Pocket 3 BLE -> Wi-Fi connection coordinator.
 *
 * The wire sequence and Android Wi-Fi join are intentionally taken from Osmosis' proven connection
 * implementation (MIT licensed), with the media/gallery pieces removed. This class does only the part
 * we need before gimbal control:
 *
 * scan -> GATT -> 00/2B[04 00] -> pairing -> 53/10 wake -> read SSID/password ->
 * WifiNetworkSpecifier join -> bind process to the Pocket 3 network.
 */
class Pocket3ConnectionManager(
    context: Context,
    private val listener: Listener,
) : OsmoScanner.Listener {

    interface Listener {
        fun onConnectionLog(message: String)
        fun onConnectionState(message: String)
        fun onPairingApprovalRequired()
        fun onPocket3Network(network: Network, link: LinkProperties?)
        fun onPocket3NetworkLost()
        fun onConnectionFailed(message: String)
    }

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val bluetoothAdapter: BluetoothAdapter? =
        (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var scanner: OsmoScanner? = null
    private var gattClient: GattClient? = null
    private var apJoiner: ApJoiner? = null

    private var pairingStarted = false
    private var pairedFlowStarted = false
    private var wifiJoinStarted = false
    private var networkReady = false
    private var lastPairStatus = -99
    private var ssid = ""
    private var password = ""
    private var connectGeneration = 0

    private var bleKeepaliveOn = false
    private val bleKeepalive = object : Runnable {
        override fun run() {
            if (!bleKeepaliveOn) return
            gattClient?.writeCommand(OsmoCommands.sessionPing(OsmoCommands.SESSION_KEEPALIVE))
            main.postDelayed(this, 1000L)
        }
    }

    fun start() {
        teardown()
        connectGeneration++
        val generation = connectGeneration
        pairingStarted = false
        pairedFlowStarted = false
        wifiJoinStarted = false
        networkReady = false
        lastPairStatus = -99
        ssid = ""
        password = ""

        val adapter = bluetoothAdapter
        if (adapter == null) {
            fail("This phone has no Bluetooth adapter")
            return
        }
        if (!adapter.isEnabled) {
            fail("Bluetooth is off. Turn Bluetooth on and press CONNECT again.")
            return
        }

        listener.onConnectionState("Scanning for Pocket 3 over Bluetooth …")
        listener.onConnectionLog("BLE: scanning specifically for Osmo Pocket 3")
        scanner = OsmoScanner(adapter, this).also { it.start() }

        main.postDelayed({
            if (generation == connectGeneration && gattClient == null && !networkReady) {
                scanner?.stop()
                fail("Pocket 3 was not found over Bluetooth within 12 seconds. Make sure it is powered on and nearby.")
            }
        }, 12_000L)
    }

    fun teardown() {
        connectGeneration++
        stopBleKeepalive()
        scanner?.stop()
        scanner = null
        runCatching { gattClient?.disconnect() }
        runCatching { gattClient?.close() }
        gattClient = null
        apJoiner?.release()
        apJoiner = null
        networkReady = false
    }

    // ---- OsmoScanner.Listener -----------------------------------------------------------------

    override fun onLog(s: String) = listener.onConnectionLog(s)

    override fun onHit(
        device: BluetoothDevice,
        rssi: Int,
        name: String?,
        modelGuess: String?,
        modelId: Int?,
    ) {
        val n = name.orEmpty().lowercase().replace(" ", "")
        val isPocket3 = modelId == 0x0020 || n.contains("pocket3") || modelGuess == "OsmoPocket3"
        if (!isPocket3) {
            listener.onConnectionLog("BLE: ignoring DJI device ${name ?: device.address}; not Pocket 3")
            return
        }
        if (gattClient != null) return

        scanner?.stop()
        listener.onConnectionState("Pocket 3 found — opening Bluetooth session …")
        listener.onConnectionLog(
            "BLE: Pocket 3 found ${device.address}, rssi=$rssi, name=${name ?: "?"}, model=${modelGuess ?: "?"}"
        )
        val generation = connectGeneration
        val gc = GattClient(appContext, object : GattClient.Listener {
            override fun onLog(s: String) {
                if (generation == connectGeneration) listener.onConnectionLog(s)
            }

            override fun onReady(gatt: GattClient) {
                if (generation == connectGeneration) handleGattReady(gatt)
            }

            override fun onNotification(sourceChar: UUID, raw: ByteArray, parsed: DjiMessage?) {
                if (generation == connectGeneration) this@Pocket3ConnectionManager.handleGattNotification(sourceChar, raw, parsed)
            }

            override fun onDisconnected() {
                if (generation == connectGeneration) this@Pocket3ConnectionManager.handleGattDisconnected()
            }
        })
        gattClient = gc
        gc.connect(device)
    }

    // ---- GattClient.Listener ------------------------------------------------------------------

    private fun handleGattReady(gatt: GattClient) {
        listener.onConnectionState("Bluetooth ready — waking/pairing Pocket 3 …")

        // Exact Mimo/Osmosis ordering: SESSION_WAKE first, then SetPairingPIN after a short gap.
        val wakeOk = gatt.writeCommand(OsmoCommands.sessionPing(OsmoCommands.SESSION_WAKE))
        listener.onConnectionLog("BLE: sent 00/2B [04 00] session wake, ok=$wakeOk")

        val generation = connectGeneration
        main.postDelayed({
            if (generation != connectGeneration || pairingStarted || gattClient == null) return@postDelayed
            pairingStarted = true
            val ok = gattClient?.writeCommand(OsmoCommands.setPairingPin("osmo")) ?: false
            listener.onConnectionLog("BLE: sent SetPairingPIN token=\"osmo\", ok=$ok")
        }, 120L)

        // fff5 is write-without-response; Osmosis retries the pairing frame if the first one vanished.
        for (delay in longArrayOf(2500L, 5000L)) {
            main.postDelayed({
                if (generation == connectGeneration && !pairedFlowStarted && lastPairStatus == -99 && gattClient != null) {
                    val ok = gattClient?.writeCommand(OsmoCommands.setPairingPin("osmo")) ?: false
                    listener.onConnectionLog("BLE: no pairing reply yet — retry SetPairingPIN, ok=$ok")
                }
            }, delay)
        }
    }

    private fun handleGattNotification(sourceChar: UUID, raw: ByteArray, parsed: DjiMessage?) {
        if (parsed == null) return

        // DJI sends requests that MUST be answered. Osmosis mirrors the request as a response,
        // swaps target bytes, and uses APP_DEVICE_INFO for the 00/81 identity request.
        if (parsed.flags == 0x40) {
            val responseTarget = ((parsed.target and 0xFF) shl 8) or ((parsed.target ushr 8) and 0xFF)
            val responseType = (parsed.type and 0xFFFF00) or 0xC0
            val responsePayload = if (parsed.cmdSet == 0x00 && parsed.cmdId == 0x81) {
                OsmoCommands.APP_DEVICE_INFO
            } else {
                parsed.payload
            }
            val response = DjiMessage(responseTarget, parsed.id, responseType, responsePayload).encode()
            val ok = gattClient?.writeCommand(response) ?: false
            listener.onConnectionLog(
                "BLE: request %02X/%02X -> response ok=%s".format(parsed.cmdSet, parsed.cmdId, ok)
            )

            if (parsed.cmdSet == 0x07 && parsed.cmdId == 0x46) {
                listener.onConnectionLog("BLE: pairing approved by Pocket 3")
                onPaired()
            }
            return
        }

        if (parsed.cmdSet == 0x07) {
            when (parsed.cmdId) {
                0x45 -> {
                    val status = parsed.payload.getOrNull(1)?.toInt()?.and(0xFF) ?: -1
                    lastPairStatus = status
                    when (status) {
                        0x01 -> {
                            listener.onConnectionLog("BLE: Pocket 3 says ALREADY PAIRED")
                            onPaired()
                        }
                        0x02 -> {
                            listener.onConnectionLog("BLE: Pocket 3 requires pairing approval on its screen")
                            main.post { listener.onPairingApprovalRequired() }
                        }
                        else -> listener.onConnectionLog("BLE: pairing status=0x%02X".format(status))
                    }
                }
                0x46 -> {
                    listener.onConnectionLog("BLE: pairing approved")
                    onPaired()
                }
                0x07 -> {
                    parseStatusPackString(parsed.payload)?.takeIf { it.isNotBlank() }?.let {
                        ssid = it
                        listener.onConnectionLog("BLE: Wi-Fi SSID retrieved: \"$it\"")
                        maybeJoinWifi()
                    }
                }
                0x0E -> {
                    val p = parseStatusPackString(parsed.payload)
                    if (!p.isNullOrEmpty()) {
                        password = p
                        listener.onConnectionLog("BLE: Wi-Fi password retrieved (${p.length} characters)")
                        maybeJoinWifi()
                    } else {
                        listener.onConnectionLog("BLE: password query returned no password")
                    }
                }
                else -> listener.onConnectionLog(
                    "BLE: 07/%02X reply payload=%s".format(parsed.cmdId, parsed.payload.toHex())
                )
            }
            return
        }

        if (parsed.cmdSet == 0x53 && parsed.cmdId == 0x10) {
            listener.onConnectionLog("BLE: 53/10 wake reply ${parsed.payload.toHex()}")
        }
    }

    private fun handleGattDisconnected() {
        stopBleKeepalive()
        gattClient?.close()
        gattClient = null
        if (networkReady || wifiJoinStarted) {
            listener.onConnectionLog("BLE: disconnected during/after Wi-Fi handoff (not treated as a failure)")
        } else {
            fail("Bluetooth link to Pocket 3 disconnected before Wi-Fi handoff completed")
        }
    }

    private fun onPaired() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { onPaired() }
            return
        }
        if (pairedFlowStarted) return
        pairedFlowStarted = true
        listener.onConnectionState("Paired — waking Pocket 3 Wi-Fi …")
        listener.onConnectionLog("BLE: starting Osmosis/Mimo post-pair wake + credential sequence")
        startBleKeepalive()

        val generation = connectGeneration
        main.postDelayed({
            if (generation == connectGeneration) {
                val ok = gattClient?.writeCommand(OsmoCommands.session5310()) ?: false
                listener.onConnectionLog("BLE: sent 53/10 Wi-Fi wake, ok=$ok")
            }
        }, 100L)
        main.postDelayed({
            if (generation == connectGeneration) {
                val ok = gattClient?.writeCommand(OsmoCommands.wifiQuery(0x07, id = 0x8007)) ?: false
                listener.onConnectionLog("BLE: requested Pocket 3 Wi-Fi SSID, ok=$ok")
            }
        }, 900L)
        main.postDelayed({
            if (generation == connectGeneration) {
                val ok = gattClient?.writeCommand(OsmoCommands.wifiQuery(0x0E, id = 0x800E)) ?: false
                listener.onConnectionLog("BLE: requested Pocket 3 Wi-Fi password, ok=$ok")
            }
        }, 1400L)
        main.postDelayed({
            if (generation == connectGeneration && !wifiJoinStarted && (ssid.isBlank() || password.isBlank())) {
                fail("Pocket 3 paired, but its Wi-Fi credentials were not received over Bluetooth")
            }
        }, 6500L)
    }

    private fun startBleKeepalive() {
        if (bleKeepaliveOn) return
        bleKeepaliveOn = true
        listener.onConnectionLog("BLE: 00/2B [01 01] keepalive started at 1 Hz")
        main.postDelayed(bleKeepalive, 1000L)
    }

    private fun stopBleKeepalive() {
        if (!bleKeepaliveOn) return
        bleKeepaliveOn = false
        main.removeCallbacks(bleKeepalive)
    }

    private fun maybeJoinWifi() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { maybeJoinWifi() }
            return
        }
        if (wifiJoinStarted || ssid.isBlank() || password.isBlank()) return
        wifiJoinStarted = true
        listener.onConnectionState("Pocket 3 Wi-Fi waking — waiting for access point …")
        listener.onConnectionLog("WiFi: credentials complete; waiting 3 seconds for Pocket 3 AP")

        val generation = connectGeneration
        main.postDelayed({
            if (generation != connectGeneration) return@postDelayed
            listener.onConnectionState("Joining Pocket 3 Wi-Fi …")
            apJoiner?.release()
            apJoiner = ApJoiner(appContext, object : ApJoiner.Listener {
                override fun onLog(s: String) = listener.onConnectionLog(s)

                override fun onNetwork(network: Network, link: LinkProperties?) {
                    networkReady = true
                    listener.onConnectionLog(
                        "WiFi: Pocket 3 network joined; addresses=" +
                            (link?.linkAddresses?.joinToString { it.address.hostAddress ?: "?" } ?: "unknown")
                    )
                    listener.onConnectionState("Pocket 3 Wi-Fi connected — opening gimbal datalink …")
                    listener.onPocket3Network(network, link)
                }

                override fun onFailed(reason: String) {
                    fail(reason)
                }

                override fun onLost(network: Network) {
                    networkReady = false
                    listener.onConnectionLog("WiFi: Pocket 3 network LOST")
                    listener.onConnectionState("Pocket 3 Wi-Fi lost")
                    listener.onPocket3NetworkLost()
                }
            }).also { it.join(ssid, password, false) }
        }, 3000L)
    }

    private fun parseStatusPackString(payload: ByteArray): String? {
        if (payload.size < 2) return null
        val len = payload[1].toInt() and 0xFF
        if (2 + len > payload.size) return null
        return String(payload, 2, len, Charsets.US_ASCII)
    }

    private fun fail(message: String) {
        // Invalidate delayed BLE callbacks from this attempt before releasing resources.
        connectGeneration++
        stopBleKeepalive()
        scanner?.stop()
        scanner = null
        runCatching { gattClient?.close() }
        gattClient = null
        apJoiner?.release()
        apJoiner = null
        networkReady = false
        listener.onConnectionLog("CONNECTION ERROR: $message")
        listener.onConnectionState("Connection failed")
        listener.onConnectionFailed(message)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}
