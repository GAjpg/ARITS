package com.hackathon.elevator

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View

/**
 * 「**App 到底看到了什么**」——把识别用的那幅图原样画在屏幕上。
 *
 * 画的不是相机画面，而是**算法真正拿去认数字的那张图**：
 *   · 多帧融合后的红色强度（越亮的地方越红）
 *   · 阈值切出来的亮点（粉色）—— 数字就是由这些点拼出来的
 *   · 它认出来的数字框（绿框）
 *
 * 现场调的时候，这一小块能立刻告诉你问题出在哪：
 *   全黑 → 没对准 / 太远 / 屏没亮；有亮点但没绿框 → 点阵没拼成字；
 *   有绿框但数字不对 → 该用"现场教一下"兜底。
 */
class MaskView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var bmp: Bitmap? = null
    private var px: IntArray = IntArray(0)
    private var iw = 0
    private var ih = 0
    private var boxes: List<DotMatrixReader.Box> = emptyList()
    private var label = ""

    private val dst = RectF()
    private val src = Rect()
    private val bmpPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f
        color = Color.parseColor("#5BE7A0")
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#5BE7A0")
        textSize = 15f
        isFakeBoldText = true
    }

    /**
     * 画一帧。
     *
     * @param red    融合后的红色强度（长 = w*h）
     * @param peak   这一帧里最强的红（用来定阈值、定亮度）
     * @param boxes  [DotMatrixReader] 认出来的数字位
     * @param label  认出来的数（显示在左上角），空串 = 没认到
     */
    fun setFrame(
        red: FloatArray,
        w: Int,
        h: Int,
        peak: Float,
        boxes: List<DotMatrixReader.Box>,
        label: String
    ) {
        if (w <= 0 || h <= 0 || red.size < w * h) return
        if (bmp == null || iw != w || ih != h) {
            bmp?.recycle()
            bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            px = IntArray(w * h)
            iw = w
            ih = h
        }
        val thr = peak * DotMatrixReader.RED_THR_RATIO
        val inv = if (peak > 1f) 1f / peak else 0f
        val opaque = 0xFF000000.toInt()
        val n = w * h
        for (i in 0 until n) {
            val v = red[i]
            val g = (v * inv * 255f).toInt().coerceIn(0, 255)
            px[i] = if (peak >= DotMatrixReader.MIN_RED_PEAK && v >= thr) {
                opaque or (0xFF shl 16) or (0x50 shl 8) or 0x70   // 亮点：粉红
            } else {
                opaque or (g shl 16) or (g shl 8) or g            // 背景：灰
            }
        }
        bmp?.setPixels(px, 0, w, 0, 0, w, h)
        this.boxes = boxes
        this.label = label
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val b = bmp ?: return
        val pad = 1f
        val vw = width - pad * 2f
        val vh = height - pad * 2f
        if (vw <= 1f || vh <= 1f) return
        val s = minOf(vw / iw.toFloat(), vh / ih.toFloat())   // 等比缩小，别拉变形
        val dw = iw * s
        val dh = ih * s
        dst.set(
            pad + (vw - dw) / 2f,
            pad + (vh - dh) / 2f,
            pad + (vw + dw) / 2f,
            pad + (vh + dh) / 2f
        )
        src.set(0, 0, iw, ih)
        canvas.drawBitmap(b, src, dst, bmpPaint)

        for (bx in boxes) {
            canvas.drawRect(
                dst.left + bx.x0 * s,
                dst.top + bx.y0 * s,
                dst.left + bx.x1 * s,
                dst.top + bx.y1 * s,
                boxPaint
            )
        }
        if (label.isNotEmpty()) canvas.drawText(label, dst.left + 2f, dst.top + 14f, textPaint)
    }
}
