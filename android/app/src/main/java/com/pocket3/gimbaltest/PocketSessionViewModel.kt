package com.pocket3.gimbaltest

import android.app.Application
import android.net.LinkProperties
import android.net.Network
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import com.pocket3.gimbaltest.ui.publicsafe.KazeConnectionPhase
import java.util.concurrent.Executors

/** Retains the one Pocket connection/session owner while Activity UI instances come and go. */
class PocketSessionViewModel(application: Application) : AndroidViewModel(application) {
    private var activityListener: Pocket3ConnectionManager.Listener? = null

    val worker = Executors.newSingleThreadExecutor()
    val session = GimbalSession(::relayLog)
    val connection = Pocket3ConnectionManager(application, object : Pocket3ConnectionManager.Listener {
        override fun onConnectionLog(message: String) = relayLog(message)
        override fun onConnectionState(message: String) {
            connectionDetail = message
            activityListener?.onConnectionState(message)
        }
        override fun onPairingApprovalRequired() {
            activityListener?.onPairingApprovalRequired()
        }
        override fun onPocket3Network(network: Network, link: LinkProperties?) {
            activityListener?.onPocket3Network(network, link)
        }
        override fun onPocket3NetworkLost() {
            activityListener?.onPocket3NetworkLost()
        }
        override fun onConnectionFailed(message: String) {
            activityListener?.onConnectionFailed(message)
        }
    })

    var connectionPhase = KazeConnectionPhase.DISCONNECTED
    var connectionDetail = "Disconnected"
    var capturedCenter: GimbalTelemetry? = null

    fun attach(listener: Pocket3ConnectionManager.Listener) {
        activityListener = listener
        relayLog("Pocket session retained; connected=${session.connected}")
    }

    fun detach(listener: Pocket3ConnectionManager.Listener) {
        if (activityListener === listener) activityListener = null
    }

    private fun relayLog(message: String) {
        val listener = activityListener
        if (listener != null) listener.onConnectionLog(message)
        else Log.i(MainActivity.LOG_TAG, message)
    }

    override fun onCleared() {
        Log.i(MainActivity.LOG_TAG, "Retained Pocket owner clearing; clean shutdown requested")
        worker.execute {
            session.disconnect()
            connection.teardown()
        }
        worker.shutdown()
        super.onCleared()
    }
}
