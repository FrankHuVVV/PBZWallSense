# Changelog

## v0.1.0 — 2026-11-06

首个可用版本。

**功能**
- 隔墙标记：仅对「25 m 内 + 活着 + 未仇恨你 + 你不在战斗中 + 被几何挡住」的敌人生效
- 暗红水墨环：复用游戏 UI `wb_damageindicator_C` 的 `Image` 节点，贴 64×64 水墨环贴图，按距离缩放 20–52 px
- 底部读数（F8 开关）：敌人数 / 25m 内数量 / 待标数 / 最近距离 / 潜行或战斗中
- F7 一键开关标记

**实现要点**
- 敌人枚举：`PBZCharacter_NPC` + `BIsMonster`，排除玩家类 `BP_Renewal_Hun`
- 投影：`ProjectWorldLocationToScreen`（out 参数按表传），失败退回相机矩阵手算
- 遮挡：`KismetSystemLibrary.LineTraceSingle`
- 仇恨判定：`BP_PBZHatredManagerComponent.HatredList`
- 战斗判定：GameplayEvent 的 `InCombat` / `OffCombat` 标签 + 仇恨兜底
- 读数为直写 `PBZCommonLocRichText`，绕过提示条蓝图，**无音效、无闪烁**
- 换图后自动重建 UI；退出前自动摘除控件

**已知问题**
- 退出游戏时 UE4SS 可能产生 crash dump（`0xC0000005` @ `UE4SS.dll`），与模组无关，未安装时同样存在
