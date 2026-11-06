# ThemeBoard 0.18.2 改造清单（基线 = 0.16.9 / ce94b26）

用户决定（2026-11-06）：**只做下列四项；通知中心一律不要。**

1. 胶囊挂 host.view —— 修「胶囊弹出时要滑两次才能回桌面」；退后台只隐藏、不摘视图。
2. 设置页批量补刷：间隔 2s→3s，【滚动中直接跳过】，节点上限 120→80。
3. 时钟供图：hook SBLiveIconImageView / SBHClockApplicationIconImageView 的
   contentsImage / squareContentsImage（4 个独立 orig 槽），只对 com.apple.mobiletimer
   返回主题表盘，无素材走原实现。
4. 分享面板：TBImageForBundle 增加「扩展 id → 宿主 bundleID」前缀归并（最多截断 3 层）。

## 禁止（永不并入）
- NCBadgedIconView -_configureBadgedIconViewIfNecessary（0.18.0 / 40f68eb）
- 任何 NC / 横幅 / 通知链路 hook；0.17.x 的 NC 观测探针也不要加回。
  原因：17.2 实测替换 0 命中 + 横幅不显示 + SpringBoard 反复重启（卡菊花）。

## 构建
引擎必须 CI(macOS) 或 Mac 构建。设备端自建 dylib 加载即死（无日志 + 菊花），不可用。
