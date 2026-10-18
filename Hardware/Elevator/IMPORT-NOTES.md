# 电梯交互源码导入说明

本目录由本队电梯交互硬件负责成员提供，原始文件保持内容不变。导入日期为 2026-10-18，来源包为 `最终代码_固件与App_v1(1).zip`。逐文件 SHA-256 与来源包哈希见 `SOURCE-MANIFEST.json`。

## 内容

- `android/`：独立电梯交互 Android App，包含 BLE、楼层来源和导航模拟等功能；不是校园室外导航 Android 工程。
- `firmware/elevator_1F/` 与 `firmware/elevator_2F/`：1F、2F 呼梯板，广播名 ELEV-1F、ELEV-2F。
- `firmware/chime_node/`：可选到站提示原型，原始注释标注未实测。
- 原始交接 `README.md` 标记 App v12、固件 v8；Android 构建脚本中的 versionName 仍为 1.0、versionCode 为 1，导入时未修改这些值。

## 构建注意

Android 工程使用 AGP 8.5.2、Kotlin 1.9.24、Gradle wrapper 8.7、Java 17，compileSdk/targetSdk 34、minSdk 24，以随附构建脚本为准。

原始 `android/gradle.properties` 固定了 `org.gradle.java.home=D:/Android/jdk-17.0.20.1+1`。在其他电脑构建前，应调整该项，或删除该项并配置 JDK 17。原文件保持不变；gradlew 在 Git 中设为可执行。Gradle wrapper JAR 保留上游内嵌 META-INF/LICENSE。

固件使用 Arduino-ESP32 的 BLE、Preferences 和 FreeRTOS 相关接口；包内未锁定板级核心版本。根据原始 README 选择 ESP32 Dev Module 与相应分区，并按实际机械装配标定舵机角度。不要把到站提示原型注释当作已完成现场验收。

## 文档与验证范围

原始 README 提到 BLE_PROTOCOL.md、NAV_APP_UI_SPEC.md、SHAFT_MODEL.md、API.md、HANDOVER.md、REPORT.md，但此源码包未附这些文档。本次未用旧交接文件冒充本版本配套说明。

已检查压缩包 CRC、路径、XML 语法以及 47 份原始文件逐字节一致性；未执行 Android 构建、固件编译或现场硬件联调。本次只收录源码，不修改现有 iOS 呼梯逻辑，也不代表新版硬件的全部能力已接入 iOS。

外部依赖及来源见仓库根目录 THIRD_PARTY_NOTICES.md。团队成员的个人署名和本队代码对外发布许可待团队统一补充。
