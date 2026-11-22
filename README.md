# GTNH-Client-Migrator

A lightweight BAT tool for Prism Launcher. Migrate GTNH client settings and data to a newer instance.

适用于 Windows 上的 Prism Launcher，使用系统自带的 Windows PowerShell。新旧实例需要放在同一个 Prism 实例目录里。

## 使用方法

1. 在 Prism 中导入新版 GTNH，保留旧实例。
2. 双击下载的 BAT，选择「预览并迁移」。从自动找到的目录中选择一项，也可以粘贴 Prism 根目录或实例目录。
3. 依次选择旧实例、新实例，检查预览。确认后输入 `Y` 迁移。

预览中，`Add` 表示新增，`Replace` 表示覆盖并备份，`Unchanged` 表示两边内容相同。

## 迁移范围

迁移游戏选项和按键、服务器列表、JourneyMap 地图与路标、VisualProspecting 矿脉、TCNodeTracker 神秘节点及 NEI 全局数据。这个工具面向多人客户端，单人世界请另行迁移。

## 回滚

每次迁移的备份都保存在新实例目录下的 `.gtnh-migration`。关闭 Minecraft，重新打开 BAT，选择「回滚」，再选择目标实例和备份编号。回滚会恢复被替换的文件并撤销新增文件。若检查发现目标文件在迁移后已被改写，会显示对应路径并中止。

目录查找或手动迁移可参考 [Prism 数据目录文档](https://prismlauncher.org/wiki/getting-started/data-location/) 和 [GTNH 客户端迁移指南](https://gtnh.huijiwiki.com/wiki/安装游戏)。
