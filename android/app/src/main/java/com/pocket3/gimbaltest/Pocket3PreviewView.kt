package com.pocket3.gimbaltest

import android.content.Context
import android.graphics.Color
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import kotlin.math.abs

/**
 * Preview host that keeps one SurfaceView alive while independently controlling:
 *
 * 1. the decoded source aspect ratio (normally 16:9), and
 * 2. the camera's effective capture frame (16:9, 9:16, or 1:1).
 *
 * Pocket 3 can keep sending a landscape-shaped monitoring stream while recording a
 * portrait/square crop. In those modes we center-crop the retained SurfaceView inside
 * an aspect-fitted viewport instead of stretching the decoder output.
 */
class Pocket3PreviewView(
    context: Context,
    private val output: Pocket3VideoOutput,
) : FrameLayout(context), SurfaceHolder.Callback {
    companion object {
        private const val DEFAULT_SOURCE_ASPECT = 16f / 9f
        private const val ASPECT_EPSILON = 0.001f
    }

    private val surfaceView = SurfaceView(context)
    private val viewport = CropViewport(context, surfaceView)

    private var fillDisplay = false
    private var captureAspect = DEFAULT_SOURCE_ASPECT

    init {
        setBackgroundColor(Color.BLACK)
        clipChildren = true
        clipToPadding = true
        addView(
            viewport,
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        surfaceView.holder.addCallback(this)
    }

    fun setPresentation(
        sourceWidth: Int?,
        sourceHeight: Int?,
        captureAspect: Float,
        fillDisplay: Boolean,
    ) {
        val nextSourceAspect = if (sourceWidth != null && sourceHeight != null && sourceWidth > 0 && sourceHeight > 0) {
            sourceWidth.toFloat() / sourceHeight.toFloat()
        } else {
            DEFAULT_SOURCE_ASPECT
        }
        val nextCaptureAspect = captureAspect.takeIf { it > 0f } ?: DEFAULT_SOURCE_ASPECT

        viewport.setSourceAspect(nextSourceAspect)
        if (
            this.fillDisplay != fillDisplay ||
            abs(this.captureAspect - nextCaptureAspect) > ASPECT_EPSILON
        ) {
            this.fillDisplay = fillDisplay
            this.captureAspect = nextCaptureAspect
            requestLayout()
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val availableWidth = right - left
        val availableHeight = bottom - top
        if (availableWidth <= 0 || availableHeight <= 0) return

        val bounds = if (fillDisplay) {
            Bounds(0, 0, availableWidth, availableHeight)
        } else {
            aspectFitBounds(availableWidth, availableHeight, captureAspect)
        }
        viewport.layout(bounds.left, bounds.top, bounds.right, bounds.bottom)
    }

    override fun surfaceCreated(holder: SurfaceHolder) = output.attachSurface(holder.surface)

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        output.attachSurface(holder.surface)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) = output.detachSurface(holder.surface)

    private data class Bounds(
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    )

    private fun aspectFitBounds(width: Int, height: Int, aspect: Float): Bounds {
        val containerAspect = width.toFloat() / height.toFloat()
        val fittedWidth: Int
        val fittedHeight: Int
        if (containerAspect > aspect) {
            fittedHeight = height
            fittedWidth = (height * aspect).toInt()
        } else {
            fittedWidth = width
            fittedHeight = (width / aspect).toInt()
        }
        val fittedLeft = (width - fittedWidth) / 2
        val fittedTop = (height - fittedHeight) / 2
        return Bounds(fittedLeft, fittedTop, fittedLeft + fittedWidth, fittedTop + fittedHeight)
    }

    private class CropViewport(
        context: Context,
        private val surfaceView: SurfaceView,
    ) : FrameLayout(context) {
        private var sourceAspect = DEFAULT_SOURCE_ASPECT

        init {
            setBackgroundColor(Color.BLACK)
            clipChildren = true
            clipToPadding = true
            addView(
                surfaceView,
                LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
            )
        }

        fun setSourceAspect(aspect: Float) {
            if (abs(sourceAspect - aspect) > ASPECT_EPSILON) {
                sourceAspect = aspect
                requestLayout()
            }
        }

        override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
            val width = right - left
            val height = bottom - top
            if (width <= 0 || height <= 0) return

            val containerAspect = width.toFloat() / height.toFloat()
            val childWidth: Int
            val childHeight: Int
            if (containerAspect > sourceAspect) {
                childWidth = width
                childHeight = (width / sourceAspect).toInt()
            } else {
                childHeight = height
                childWidth = (height * sourceAspect).toInt()
            }
            val childLeft = (width - childWidth) / 2
            val childTop = (height - childHeight) / 2
            surfaceView.layout(childLeft, childTop, childLeft + childWidth, childTop + childHeight)
        }
    }
}
