package com.pocket3.gimbaltest

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

/** One-axis touch control used by the iOS-parity dual YAW / PITCH layout. */
class AxisJoystickView(
    context: Context,
    private val axis: Axis,
) : View(context) {
    enum class Axis { YAW, PITCH }

    var onAxis: ((value: Int, active: Boolean) -> Unit)? = null

    var responseMode: JoystickResponseMode = JoystickResponseMode.LINEAR
        private set

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 72
        strokeWidth = 2f
        style = Paint.Style.STROKE
    }
    private val centerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 52
        strokeWidth = 2f
    }
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(205, 210, 216)
        alpha = 210
    }
    private var normalized = 0f

    fun setResponseMode(mode: JoystickResponseMode) {
        responseMode = mode
        if (!isPressed) releaseAxis()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val pad = 9f
        if (axis == Axis.YAW) {
            val left = pad
            val right = width - pad
            canvas.drawLine(left, cy, right, cy, trackPaint)
            canvas.drawLine(cx, cy - 12f, cx, cy + 12f, centerPaint)
            val x = cx + normalized * ((right - left) / 2f)
            canvas.drawCircle(x, cy, 15f, knobPaint)
        } else {
            val top = pad
            val bottom = height - pad
            canvas.drawLine(cx, top, cx, bottom, trackPaint)
            canvas.drawLine(cx - 12f, cy, cx + 12f, cy, centerPaint)
            val y = cy + normalized * ((bottom - top) / 2f)
            canvas.drawCircle(cx, y, 15f, knobPaint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                isPressed = true
                normalized = if (axis == Axis.YAW) {
                    ((event.x - width / 2f) / ((width - 18f) / 2f)).coerceIn(-1f, 1f)
                } else {
                    ((event.y - height / 2f) / ((height - 18f) / 2f)).coerceIn(-1f, 1f)
                }
                if (abs(normalized) < 0.001f) normalized = 0f
                invalidate()
                val command = if (axis == Axis.YAW) {
                    JoystickResponse.mapNormalized(normalized, 0f, responseMode)
                } else {
                    JoystickResponse.mapNormalized(0f, normalized, responseMode)
                }
                onAxis?.invoke(if (axis == Axis.YAW) command.yaw else command.pitch, true)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                isPressed = false
                releaseAxis()
                parent?.requestDisallowInterceptTouchEvent(false)
                performClick()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    private fun releaseAxis() {
        normalized = 0f
        invalidate()
        onAxis?.invoke(JoystickResponse.NEUTRAL, false)
    }
}
