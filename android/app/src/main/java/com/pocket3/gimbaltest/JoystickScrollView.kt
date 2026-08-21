package com.pocket3.gimbaltest

import android.content.Context
import android.view.MotionEvent
import android.widget.ScrollView

/** Scroll container that gives an active joystick gesture exclusive ownership until release. */
class JoystickScrollView(context: Context) : ScrollView(context) {
    private var joystickGestureActive = false

    fun setJoystickGestureActive(active: Boolean) {
        joystickGestureActive = active
        requestDisallowInterceptTouchEvent(active)
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (joystickGestureActive) return false
        return super.onInterceptTouchEvent(event)
    }
}
