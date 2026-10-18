package com.hackathon.elevator

import android.os.SystemClock

/**
 * 「**轿厢现在在哪一层**」的唯一出处 —— 整个 App 只认这几个数。
 *
 * ## 为什么要有这么一个东西
 * 主界面那个大大的楼层数字、3D 井道里的轿厢、给队友 App 用的 `/api/status` 里的
 * `car` 字段，**必须是同一个数**。
 *
 * ## 这个数从哪来（优先级从高到低）
 * 1. **真读数**：摄像头读到电梯厅那块屏上的数字（方案 D），或现场手动指定（"现场教一下"）。
 * 2. **蓝牙判层**：没有真读数时，用"**手机靠近哪一层的 ESP32**"来当这一层 ——
 *    **用户坐在轿厢里**的时候，这就是轿厢所在的楼层；不是瞎猜，是量出来的
 *    （蓝牙信号强弱，规格见 `BLE_PROTOCOL.md` 的 RSSI 判层）。
 *    装置只装在 **1F / 2F**，所以只有这两层判得出来（B / 3F 没装置，那两层判不出来）。
 *
 * ## 为什么有两台（slot 0 / slot 1）
 * 一栋楼里并排两台电梯是常态，厅里那块横向屏**左边一位 = 甲梯、右边一位 = 乙梯**。
 * 我们那个点阵识别算法一次就会把每个数字位都读出来，所以**一台摄像头就能同时
 * 盯两台**。只有一位的楼（或只读到一位）也没关系：那就只更新甲梯，乙梯留空。
 * （蓝牙判层只给甲梯用 —— 我们呼梯装置装的那一台。）
 *
 * ## 为什么会"过期"
 * 摄像头读到的楼层是**那一刻**的。过一会儿没人再看它，它就不该继续冒充"实时"，
 * 所以有个 [FRESH_MS]：超时后 [current] 返回 null，界面自动退回**蓝牙判层**，
 * 而且在界面上**写清楚**这个数字是什么来路、多久之前读的（不糊弄人）。
 */
object CarFloorSource {

    /** 摄像头读出来的（方案 D） */
    const val SRC_CAMERA = "camera"

    /** 现场手动指定的（"现场教一下"兜底） */
    const val SRC_MANUAL = "manual"

    /** 读数多久算"还新鲜"。超过就自动退回"蓝牙判层"。 */
    const val FRESH_MS = 180_000L

    /** 同时盯几台电梯 */
    const val CARS = 2

    /** 0 = 甲梯（厅里屏左边那位），1 = 乙梯（右边那位） */
    private val floors = arrayOfNulls<String>(CARS)
    private val sources = arrayOfNulls<String>(CARS)
    private val ats = LongArray(CARS)

    /** 记下一台电梯的真实读数。 */
    @Synchronized
    fun set(slot: Int, f: String, src: String, now: Long = SystemClock.elapsedRealtime()) {
        if (slot !in 0 until CARS) return
        floors[slot] = f
        sources[slot] = src
        ats[slot] = now
    }

    /** 忘掉一台（slot < 0 = 全忘掉）。 */
    @Synchronized
    fun clear(slot: Int = -1) {
        val from = if (slot < 0) 0 else slot
        val to = if (slot < 0) CARS - 1 else slot
        for (i in from..to) {
            if (i !in 0 until CARS) continue
            floors[i] = null
            sources[i] = null
            ats[i] = 0L
        }
    }

    /** 这台电梯还没过期的真实楼层；没有/过期都返回 null（调用方就该退回"蓝牙判层"）。 */
    @Synchronized
    fun current(slot: Int = 0, now: Long = SystemClock.elapsedRealtime()): String? {
        if (slot !in 0 until CARS) return null
        val f = floors[slot] ?: return null
        return if (now - ats[slot] <= FRESH_MS) f else null
    }

    /** 距离上次读数的毫秒数；从没读过返回 -1。 */
    @Synchronized
    fun ageMs(slot: Int = 0, now: Long = SystemClock.elapsedRealtime()): Long {
        if (slot !in 0 until CARS || floors[slot] == null) return -1L
        return (now - ats[slot]).coerceAtLeast(0L)
    }

    /** 这一台读数是刚读的，还是我们手动指的。 */
    @Synchronized
    fun sourceLabel(slot: Int = 0): String? = when (sources.getOrNull(slot)) {
        SRC_CAMERA -> "摄像头"
        SRC_MANUAL -> "手动指定"
        else -> null
    }

    /** 给接口用的机器可读版本：`camera` / `manual`。 */
    @Synchronized
    fun sourceCode(slot: Int = 0): String? = sources.getOrNull(slot)

    /** 人话版的"多久之前"：刚刚 / 12 秒前 / 2 分钟前。 */
    fun ageText(slot: Int = 0, now: Long = SystemClock.elapsedRealtime()): String {
        val a = ageMs(slot, now)
        if (a < 0) return ""
        val s = a / 1000
        return when {
            s <= 1 -> "刚刚"
            s < 60 -> "${s} 秒前"
            else -> "${s / 60} 分钟前"
        }
    }

    /**
     * （**备用**）把两台电梯的"在哪层 + 这个数哪来的"拼成一行小字。三种写法：
     *   `甲 3F 真·摄像头·刚刚`（真读到了）
     *   `甲 1F 蓝牙判层`（没读到真值，用的是"你靠近哪层"）
     *   `甲 3F 真·摄像头·刚刚　乙 1F 真·摄像头·刚刚`（两台都读到了）
     *
     * ⚠️ **v9 起界面上不再显示这行**（用户要求"层显下面不要小字"）：主界面两台层显只放大数字，
     * 「队友 App 效果」页顶部那张卡用的是 [sourceLabel] + [ageText]。这个函数留着备用
     * —— 哪天想把"来源"再加回界面上，直接调它就行。
     *
     * @param near 蓝牙判层的结果：手机靠近哪层（只给甲梯用）
     */
    fun lineText(near: String? = null, now: Long = SystemClock.elapsedRealtime()): String {
        val a = current(0, now)
        val b = current(1, now)
        val carA = a ?: near
        if (carA == null && b == null) return ""
        val sb = StringBuilder()
        if (carA != null) {
            sb.append("甲 ").append(carA)
            sb.append(if (a != null) " 真·${sourceLabel(0)}·${ageText(0, now)}" else " 蓝牙判层")
        }
        if (b != null) {
            if (sb.isNotEmpty()) sb.append("　")
            sb.append("乙 ").append(b)
            sb.append(" 真·${sourceLabel(1)}·${ageText(1, now)}")
        }
        return sb.toString()
    }
}
