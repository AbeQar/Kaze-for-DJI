package com.pocket3.gimbaltest

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Two-axis virtual joystick with two selectable response profiles.
 *
 * LINEAR preserves the v0.13 behavior exactly: direct proportional mapping with +/-330 command units.
 * PROGRESSIVE keeps the full observed +/-550 ceiling but uses a more aggressive mid-stick
 * response so deliberate medium/large deflections reach high speed sooner while the center stays soft.
 */
class JoystickView(context: Context) : View(context) {
    var onJoystick: ((pitch: Int, yaw: Int, active: Boolean) -> Unit)? = null
    var onGestureOwnershipChanged: ((active: Boolean) -> Unit)? = null

    var responseMode: JoystickResponseMode = JoystickResponseMode.LINEAR
        private set

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = 2f
        alpha = 72
    }
    private val crossPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = 2f
        alpha = 52
    }
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.rgb(205, 210, 216)
        alpha = 205
    }
    private val knobOutlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = 2f
        alpha = 205
    }

    private var knobX = 0f
    private var knobY = 0f

    fun setResponseMode(mode: JoystickResponseMode) {
        responseMode = mode
        if (!isPressed) {
            centerAndRelease()
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        knobX = w / 2f
        knobY = h / 2f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val radius = min(width, height) * 0.39f
        val knobRadius = radius * 0.25f

        canvas.drawCircle(cx, cy, radius, ringPaint)
        canvas.drawLine(cx - radius, cy, cx + radius, cy, crossPaint)
        canvas.drawLine(cx, cy - radius, cx, cy + radius, crossPaint)
        canvas.drawCircle(knobX, knobY, knobRadius, knobPaint)
        canvas.drawCircle(knobX, knobY, knobRadius, knobOutlinePaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                onGestureOwnershipChanged?.invoke(true)
                parent?.requestDisallowInterceptTouchEvent(true)
                isPressed = true
                updateFromTouch(event.x, event.y)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                // Reassert ownership for the complete gesture on devices that re-evaluate vertical
                // interception after touch slop is crossed.
                parent?.requestDisallowInterceptTouchEvent(true)
                isPressed = true
                updateFromTouch(event.x, event.y)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                isPressed = false
                centerAndRelease()
                onGestureOwnershipChanged?.invoke(false)
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

    private fun updateFromTouch(x: Float, y: Float) {
        val cx = width / 2f
        val cy = height / 2f
        val radius = min(width, height) * 0.39f
        var dx = x - cx
        var dy = y - cy
        val distance = sqrt(dx * dx + dy * dy)
        if (distance > radius && distance > 0f) {
            val scale = radius / distance
            dx *= scale
            dy *= scale
        }

        knobX = cx + dx
        knobY = cy + dy
        invalidate()

        val command = JoystickResponse.mapNormalized(
            normalizedX = dx / radius,
            normalizedY = dy / radius,
            mode = responseMode,
        )
        onJoystick?.invoke(command.pitch, command.yaw, true)
    }

    private fun centerAndRelease() {
        knobX = width / 2f
        knobY = height / 2f
        invalidate()
        onJoystick?.invoke(JoystickResponse.NEUTRAL, JoystickResponse.NEUTRAL, false)
    }
}
