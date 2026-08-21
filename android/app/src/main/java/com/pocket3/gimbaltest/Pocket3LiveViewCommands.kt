package com.pocket3.gimbaltest

data class Pocket3LiveViewCommand(
    val set: Int,
    val command: Int,
    val payload: ByteArray,
    val receiverType: Int,
    val receiverId: Int,
    val commandType: Int,
)

data class Pocket3LiveViewStep(
    val command: Pocket3LiveViewCommand,
    val delayAfterMs: Long,
)

/** Capture-confirmed DJI Mimo direct-live-view commands and their proven ordering. */
object Pocket3LiveViewCommands {
    private val LIVE_START = bytes(0x01, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x05, 0x01)
    private val LIVE_IDLE = bytes(0x00, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x04, 0x01)
    private val LIVE_A8 = bytes(0x00, 0x04, 0x02, 0, 0, 0, 0, 0, 0, 0)

    fun startupSequence(): List<Pocket3LiveViewStep> = buildList {
        add(Pocket3LiveViewStep(startCommand(), 1))
        add(Pocket3LiveViewStep(a8Command(), 1))
        add(Pocket3LiveViewStep(startCommand(), 1))
        add(Pocket3LiveViewStep(a8Command(), 1))
        repeat(5) { add(Pocket3LiveViewStep(startCommand(), 2)) }
        repeat(4) { add(Pocket3LiveViewStep(idleCommand(), 2)) }
    }

    fun shutdownSequence(): List<Pocket3LiveViewStep> =
        List(8) { Pocket3LiveViewStep(idleCommand(), 3) }

    fun startCommand() = Pocket3LiveViewCommand(
        set = 0x01, command = 0x01, payload = LIVE_START.copyOf(),
        receiverType = 0x01, receiverId = 0, commandType = 0,
    )

    fun idleCommand() = Pocket3LiveViewCommand(
        set = 0x01, command = 0x01, payload = LIVE_IDLE.copyOf(),
        receiverType = 0x01, receiverId = 0, commandType = 0,
    )

    fun a8Command() = Pocket3LiveViewCommand(
        set = 0x09, command = 0xA8, payload = LIVE_A8.copyOf(),
        receiverType = 0x01, receiverId = 2, commandType = 2,
    )

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
}
