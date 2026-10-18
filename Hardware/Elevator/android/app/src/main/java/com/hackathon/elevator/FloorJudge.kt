package com.hackathon.elevator

/**
 * 楼层判定器 —— 全 App 最核心的一小块逻辑（算法吸收自 dsh，已按其仿真结论取参）。
 *
 * 需求是“靠近哪一层的 ESP32，就说明我到了哪一层”。朴素做法是“谁信号最强就算哪层”，
 * 但真实环境里 RSSI 剧烈抖动 → 楼层指示在两层之间疯狂横跳。
 * 这里叠三层防抖：
 *
 *  1. 中位数 + 指数平滑（在 [ElevatorDevice.pushRssi] 里做）——滤毛刺
 *  2. 滞后（hysteresis）——挑战者必须比现任强出 [minLeadDb] 分贝才算赢
 *  3. 连续胜出计数——挑战者要连赢 [winCount] 次才允许换层
 */
class FloorJudge(
    leadDb: Double = 3.0,
    wins: Int = 1
) {

    /** 挑战者要比现任强多少 dB 才算赢。默认 3（想更稳就调大，调到 2 以下会开始横跳）。 */
    var minLeadDb: Double = leadDb.coerceIn(0.0, 24.0)

    /** 挑战者要连续赢几次才换层。默认 1 = 一赢就换（“瞬时”手感的来源）。 */
    var winCount: Int = wins.coerceIn(1, 10)

    /** 低于这个强度认为“离得太远，不参与判断”。 */
    var minRssi: Double = -95.0

    var currentFloor: String? = null
        private set
    var currentNode: ElevatorDevice? = null
        private set
    var challengerFloor: String? = null
        private set
    var challengerStreak: Int = 0
        private set

    /** 楼层实际变化（含从“未知”变成某层）时返回 true。 */
    fun update(nodes: List<ElevatorDevice>): Boolean {
        val candidates = nodes.filter { it.floor != null && it.filteredRssi > minRssi }

        if (candidates.isEmpty()) {
            challengerFloor = null
            challengerStreak = 0
            return if (currentFloor != null) {
                currentFloor = null
                currentNode = null
                true
            } else false
        }

        val best = candidates.maxByOrNull { it.filteredRssi }!!

        if (currentFloor == null) {
            currentFloor = best.floor
            currentNode = best
            challengerFloor = null
            challengerStreak = 0
            return true
        }

        if (best.floor == currentFloor) {
            currentNode = best
            challengerFloor = null
            challengerStreak = 0
            return false
        }

        val curRssi = currentNode?.filteredRssi ?: -127.0

        // 现任已经“够不着”了（掉电/走远/被 minRssi 判死）→ 立刻换层，不再等连赢
        val curGone = currentNode == null || curRssi <= minRssi
        if (!curGone) {
            val lead = best.filteredRssi - curRssi
            if (lead < minLeadDb) {      // 死区：领先不够，不换
                challengerFloor = null
                challengerStreak = 0
                return false
            }
        }

        if (best.floor == challengerFloor) challengerStreak++
        else { challengerFloor = best.floor; challengerStreak = 1 }

        if (curGone || challengerStreak >= winCount) {
            currentFloor = best.floor
            currentNode = best
            challengerFloor = null
            challengerStreak = 0
            return true
        }
        return false
    }

    /** 手动强制指定楼层（点楼层按钮时用）。 */
    fun forceFloor(floor: String?, node: ElevatorDevice?) {
        currentFloor = floor
        currentNode = node
        challengerFloor = null
        challengerStreak = 0
    }

    fun reset() {
        currentFloor = null
        currentNode = null
        challengerFloor = null
        challengerStreak = 0
    }
}
