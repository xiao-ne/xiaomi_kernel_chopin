# A17 震动失效的定位与修复（2026-11-03）

## 现象

A13 主系统震动正常；用 DSU 起 Android 17（GSI）后，系统里**完全没有震动**（按键、输入法、来电都不震）。

## 一、A13 基线（证明硬件与 HAL 链路本身是好的）

- AIDL 服务只有三条：
  - `android.hardware.vibrator.IVibrator/vibratorfeature`（注意实例名是 `vibratorfeature`，不是 `default`）
  - `external_vibrator_service`
  - `vibrator_manager`（Java 层 `android.os.IVibratorManagerService`，不是 HAL）
- `lshal | grep -i vibrat` 为空 —— 没有 HIDL 实现。
- `dumpsys vibrator_manager`：1 个 controller（`mId=0`、`mCapabilities=[ON_CALLBACK, PERFORM_CALLBACK]`、`flags=11`、`mSupportedEffects=[]`），且 `Previous vibrations for usage TOUCH` 里有 `TICK status: finished` 的历史记录。
- sysfs 两条通路同时存在：
  - `/sys/class/leds/vibrator -> ../../devices/platform/odm/odm:vibrator@0/leds/vibrator`（MTK PMIC 通路）
  - `/sys/bus/i2c/drivers/aw8697_haptic/9-005a/*`（aw8697 智能功放，chopin 的真实振子驱动）
- 直接写 `/sys/class/leds/vibrator/{duration,activate}` 后 `state=1`。

## 二、A17 侧的契约要求（vendor 提供 HAL，system 只提要求）

A17 的 `system/etc/vintf/compatibility_matrix.202604.xml`（第 679–694 行）要求
`android.hardware.vibrator` 同时提供：

- `IVibrator/default`（version 1–4）
- `IVibratorManager/default`（version 1–4）

而 A17 ROM 的 `vendor/etc/vintf/manifest/vendor.xiaomi.hardware.vibratorfeature.service.xml` 只声明了：

```xml
<hal format="aidl" override="true">
  <name>android.hardware.vibrator</name>
  <fqname>IVibrator/default</fqname>
</hal>
```

没有 `IVibratorManager`。A13 那份同样的文件写的是 `IVibrator/vibratorfeature`。

ServiceManager 对 AIDL HAL 是**按 manifest 强制校验**的，实测（在 A13 上前台跑厂家的 AOSP HAL）：

```
servicemanager: Could not find android.hardware.vibrator.IVibrator/default in the VINTF manifest.
android.hardware.vibrator-service.mediatek: Check failed: status == STATUS_OK
```

进程直接 SIGABRT（exit 134）。而 `/vendor/bin/hw/android.hardware.vibrator-service.mediatek`
本身是**同时实现** `IVibrator` 与 `IVibratorManager` 的（含 `BnVibratorManager`、`VibratorManager.cpp` 符号），
所以「只要让它能注册，IVibratorManager 就有了」——但本 vendor 里没有任何 rc 启动它。

## 三、决定性线索：与 ROM 自带内核逐文件比对

参考树：`freyjawionq/kernel_chopin_mt6893`（分支 `inc_ksu`，即 A17 ROM 的内核源码）。

| 项 | ROM 内核 | 我们的内核 |
|---|---|---|
| `aw8697.c` / `.h` / `_config.h` / `_reg.h` / `ringbuffer.c` | 144290 / 10621 / 3472 / 25193 / 5335 B | **完全一致** |
| DTS `aw8697_haptic@5a`（`&i2c9`、reset GPIO129、irq GPIO22、`vib_f0_pre=1700`） | 有 | 一致 |
| DTS `vibrator@0`（`mediatek,vibrator`、`vib_vol=9`） | 有 | 一致 |
| `CONFIG_INPUT_AW8697_HAPTIC` | `=y` | `=y` |
| **`CONFIG_MTK_VIBRATOR`** | **未启用（defconfig 里没有这一项）** | **`=y`** |

也就是说：驱动、DTS 都一样，**唯一差异是我们多开了 MTK PMIC 震动通路**。

推论：`CONFIG_MTK_VIBRATOR=y` 会额外注册 `/sys/class/leds/vibrator`。A17 的 vendor HAL 在探测时
很可能优先命中这条 PMIC 通路（存在即可用），而 chopin 的振子实际挂在 aw8697 上 ——
写 PMIC 节点「成功」但电机不动，于是表现为「系统里没有震动」。原厂内核没有这条通路，
HAL 只能走 aw8697，所以原厂 A17 是能震的。

## 四、修复

`arch/arm64/configs/chopin_a17_defconfig:2003`：

```
# CONFIG_MTK_VIBRATOR is not set
CONFIG_INPUT_AW8697_HAPTIC=y
```

提交：`e6a2d6149 config: keep only the aw8697 haptic path, matching the A17 reference kernel`

验证（编译产物）：

- `out/System.map` 里 `vibr_Enable|vibr_power_set|vibrator_enable` = 0 个，`aw8697` = 173 个
- `strings Image | grep -c aw8697` = 269；残留的 `led class register fail` 属于 `leds_mtk_disp`（显示 LED），与震动无关
- Image 45,385,744 B，sha256 `21f9d7e7b29958a91e54efb74a67805543982bb4438e9b87a012fe979931c51d`

交付包：`F:\刷机\boot\测试\boot-A17-vibonly-20261103_0917.img`
（134,217,728 B，sha256 `c23e006cfd5ef89f53e4c1d0fc91d0a97d130e3ba5185eb745c16e4f1d23c7ad`）

**结果：刷入后震动正常。**

## 五、回退与后续

- 回退：把 defconfig 那一行改回 `CONFIG_MTK_VIBRATOR=y` 重编即可。
- 若将来 A17 又出现无震动（例如换了 vendor 包），第一件事是看
  `service list | grep -i vibrat` 与 `dumpsys vibrator_manager` 里的 controller 数量；
  若确实卡在 manifest 契约上，备用方案是用 KernelSU 模块补一段
  `IVibratorManager/default` 的 manifest 并把 `android.hardware.vibrator-service.mediatek` 拉起来
  （模块可卸载，不动分区）。
