package com.hackathon.elevator

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View

/**
 * 「队友导航 App 效果模拟页」的背景：**一张画出来的假地图 / AR 画面**。
 *
 * 全部用 Canvas 手绘，不引入任何库、不加载任何图片：
 *   · 深蓝渐变底 + 淡网格（看着像室内地图）
 *   · 四个房间方块（A/B/C/D 区）+ 十字走廊
 *   · 一条绿色路线：从「你在这里」连到「电梯厅」
 *   · 屏幕四角的 AR 取景框
 *
 * ⚠️ 这张图**完全是为了演示好看**，不对应任何真实建筑，也没有任何数据含义。
 *    真机上这里会是队友那套 AR / 地图。
 */
class NavMapView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private fun dp(v: Float): Float = v * resources.displayMetrics.density

    private val bgPaint = Paint()

    private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)
        color = 0xFF12233A.toInt()
    }

    private val blockFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFF10203A.toInt()
    }

    private val blockStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)
        color = 0xFF1E3A54.toInt()
    }

    private val corridorPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(26f)
        strokeCap = Paint.Cap.ROUND
        color = 0xFF0D1A2B.toInt()
    }

    private val routeGlowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(12f)
        strokeCap = Paint.Cap.ROUND
        color = 0x332E9E5B.toInt()
    }

    private val routePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(4f)
        strokeCap = Paint.Cap.ROUND
        color = 0xFF2E9E5B.toInt()
    }

    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF5B7691.toInt()
        textSize = dp(11f)
    }

    private val centerLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF8AA5BE.toInt()
        textSize = dp(11f)
        textAlign = Paint.Align.CENTER
    }

    private val elevatorBox = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFF16304C.toInt()
    }

    private val elevatorDoor = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFF3E7BB8.toInt()
    }

    private val doorSplit = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(2f)
        color = 0xFF16304C.toInt()
    }

    private val youRing = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(3f)
        color = 0x804C8DFF.toInt()
    }

    private val youDot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFF4C8DFF.toInt()
    }

    private val bracketPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(2f)
        strokeCap = Paint.Cap.ROUND
        color = 0x44FFFFFF
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        bgPaint.shader = LinearGradient(
            0f, 0f, 0f, h.toFloat(),
            0xFF0C1626.toInt(), 0xFF060B13.toInt(),
            Shader.TileMode.CLAMP
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        canvas.drawRect(0f, 0f, w, h, bgPaint)
        drawGrid(canvas, w, h)
        drawRooms(canvas, w, h)
        drawCorridors(canvas, w, h)
        drawRoute(canvas, w, h)
        drawBrackets(canvas, w, h)
    }

    private fun drawGrid(canvas: Canvas, w: Float, h: Float) {
        val step = dp(32f)
        var x = 0f
        while (x < w) {
            canvas.drawLine(x, 0f, x, h, gridPaint)
            x += step
        }
        var y = 0f
        while (y < h) {
            canvas.drawLine(0f, y, w, y, gridPaint)
            y += step
        }
    }

    private fun drawRooms(canvas: Canvas, w: Float, h: Float) {
        room(canvas, w * 0.05f, h * 0.10f, w * 0.40f, h * 0.24f, "A 区 · 办公")
        room(canvas, w * 0.58f, h * 0.08f, w * 0.95f, h * 0.26f, "B 区 · 会议")
        room(canvas, w * 0.06f, h * 0.50f, w * 0.42f, h * 0.64f, "C 区 · 休息")
        room(canvas, w * 0.60f, h * 0.52f, w * 0.95f, h * 0.66f, "D 区 · 工位")
    }

    private fun room(canvas: Canvas, x0: Float, y0: Float, x1: Float, y1: Float, label: String) {
        val r = RectF(x0, y0, x1, y1)
        val rad = dp(10f)
        canvas.drawRoundRect(r, rad, rad, blockFill)
        canvas.drawRoundRect(r, rad, rad, blockStroke)
        canvas.drawText(label, x0 + dp(10f), y0 + dp(17f), labelPaint)
    }

    private fun drawCorridors(canvas: Canvas, w: Float, h: Float) {
        canvas.drawLine(w * 0.50f, h * 0.04f, w * 0.50f, h * 0.78f, corridorPaint)
        canvas.drawLine(w * 0.03f, h * 0.38f, w * 0.97f, h * 0.38f, corridorPaint)
    }

    private fun drawRoute(canvas: Canvas, w: Float, h: Float) {
        val cx = w * 0.50f
        val youY = h * 0.70f
        val liftY = h * 0.30f

        val path = Path().apply {
            moveTo(cx, youY)
            lineTo(cx, h * 0.38f)
            lineTo(cx, liftY)
        }
        canvas.drawPath(path, routeGlowPaint)
        canvas.drawPath(path, routePaint)

        // 电梯厅：一个小方块 + 两扇门
        val half = dp(17f)
        val box = RectF(cx - half, liftY - half, cx + half, liftY + half)
        canvas.drawRoundRect(box, dp(6f), dp(6f), elevatorBox)
        val inset = dp(4f)
        canvas.drawRect(
            RectF(cx - half + inset, liftY - half + inset, cx + half - inset, liftY + half - inset),
            elevatorDoor
        )
        canvas.drawLine(cx, liftY - half + inset, cx, liftY + half - inset, doorSplit)
        canvas.drawText("电梯厅", cx, liftY + half + dp(15f), centerLabelPaint)

        // 你在这里
        canvas.drawCircle(cx, youY, dp(14f), youRing)
        canvas.drawCircle(cx, youY, dp(7f), youDot)
        canvas.drawText("你在这里", cx, youY + dp(28f), centerLabelPaint)
    }

    /** 四角的 AR 取景框（纯装饰） */
    private fun drawBrackets(canvas: Canvas, w: Float, h: Float) {
        val m = dp(16f)
        val len = dp(26f)
        canvas.drawLine(m, m, m + len, m, bracketPaint)
        canvas.drawLine(m, m, m, m + len, bracketPaint)

        canvas.drawLine(w - m - len, m, w - m, m, bracketPaint)
        canvas.drawLine(w - m, m, w - m, m + len, bracketPaint)

        canvas.drawLine(m, h - m, m + len, h - m, bracketPaint)
        canvas.drawLine(m, h - m - len, m, h - m, bracketPaint)

        canvas.drawLine(w - m - len, h - m, w - m, h - m, bracketPaint)
        canvas.drawLine(w - m, h - m - len, w - m, h - m, bracketPaint)
    }
}
