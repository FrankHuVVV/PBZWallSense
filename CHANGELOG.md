# Changelog

## v0.1.5 — 2026-11-07

**文档**
- UE4SS 安装章节重写为面向零基础的四段式教程：找目录 → 下载 → 摆放（含目录结构图）→ 验证
- 明确压缩包是**扁平结构**（`UE4SS.dll` 在根目录），需要**新建 `ue4ss` 文件夹**再放进去
- 补充「装不上时按这个表查」：无日志 / 红屏 / 杀软误删 / 版本不适配 的处理办法

## v0.1.4 — 2026-11-07

**文档修正**
- 更正 README：**UE4SS 不是游戏自带**，必须自行安装。新增「先装 UE4SS」一节，含官方仓库地址
  <https://github.com/UE4SS-RE/RE-UE4SS/releases> 与安装位置、验证方法
- 补充「没有 `UE4SS.log` = UE4SS 没装好」的判断说明

## v0.1.3 — 2026-11-07

**新增**
- 游戏内热键调整锁定距离：`[` −5 m / `]` +5 m，范围 10–80 m，读数与判定立刻生效

## v0.1.2 — 2026-11-07

**新增**
- 底部读数增加**最近敌人的方位**（前 / 左前 / 左 / 左后 / 后 / 右后 / 右 / 右前），格式变为 `最近 20m·左前`
- 读数里的 `25m内` 改为跟随 `maxDistCm` 动态生成，改锁定距离后标签自动更新
- README 补充两张实机截图

## v0.1.1 — 2026-11-07

**修复**
- 贴图路径不再写死绝对路径，改为三级推导：`GetModDir()` → `package.path` 中的模组目录 → 相对路径（`ue4ss/Mods/...`）。换机器、换 Steam 库路径都能找到 `art/ring.png`

**其他**
- 新增 MIT 许可证（`LICENSE`）

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
