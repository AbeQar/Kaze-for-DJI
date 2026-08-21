package com.pocket3.gimbaltest

/** Pure Pocket 3 gimbal command encodings. Scheduling and transport remain in [GimbalSession]. */
object Pocket3GimbalCommands {
    fun velocityPayload(pitch: Int, yaw: Int): ByteArray = byteArrayOf(
        (pitch and 0xFF).toByte(), ((pitch ushr 8) and 0xFF).toByte(),
        0x00, 0x00,
        (yaw and 0xFF).toByte(), ((yaw ushr 8) and 0xFF).toByte(),
        0x00, 0x80.toByte(), 0x22, 0x00,
    )

    fun recenterPayload(): ByteArray = byteArrayOf(0xFE.toByte(), 0x08)

    fun lockPayload(locked: Boolean): ByteArray =
        byteArrayOf((if (locked) 0x00 else 0x01).toByte(), 0x00)

    fun selfieForwardPayload(): ByteArray = byteArrayOf(0xFE.toByte(), 0x09)
}
