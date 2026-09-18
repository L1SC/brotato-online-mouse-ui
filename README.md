# Brotato Online 鼠标界面补丁

`CoopFix-OnlineMouseUI` 1.0.0 以 **six666-BrotatoOnline** 为必需前置，为当前联机合作界面提供鼠标操作。

适配目标：Brotato **1.1.15.4**、游戏内置 ModLoader **6.2.0**、本机已安装 Brotato Online **6.6.6**。验证范围见 [验证记录](docs/online-mouse-ui-verification.md)。

## 操作范围

- 角色、武器和难度选择：悬停查看，左键选择；难度依照 Online 原有规则由房主选择。
- 升级选项、战利品箱拿取 / 回收 / 禁用：使用现有按钮；开启按住确认时，禁用仍须按住鼠标。
- 商店商品、背包物品、刷新、锁定及准备：左键使用现有操作；商品上的锁定和禁用图标恢复可见。准备后仅移动鼠标会保持准备；点击其他操作会按原合作规则取消准备。
- 物品详情及 ESC 暂停：通过现有详情 / 暂停界面的按钮操作。

鼠标只操作本机拥有的玩家；远程玩家的面板继续用于查看。原键盘 / 手柄操作沿用前置逻辑。

安装包下载：[Release v1.0.0](https://github.com/L1SC/brotato-online-mouse-ui/releases/tag/v1.0.0)。

## 安装

1. 完全退出游戏，确保已安装并启用 Brotato Online。
2. 将 `CoopFix-OnlineMouseUI-1.0.0.zip` 保持 ZIP 原样放到游戏安装目录的 `mods` 文件夹，**不要解压**。
3. 启动游戏，在模组菜单启用 `OnlineMouseUI / CoopFix-OnlineMouseUI`，按提示重启。

本机目标路径：

```text
D:/Program Files (x86)/Steam/steamapps/common/Brotato/mods/CoopFix-OnlineMouseUI-1.0.0.zip
```

每名需要鼠标操作的玩家在自己的电脑上安装本补丁，建议房主和所有客户端都安装。所有联机成员仍须安装 Online。本补丁的加载依赖声明会让 Online 先加载，未安装前置时不能单独启用。

卸载：停用补丁并退出游戏，删除上述补丁 ZIP 后重启。

## 实现与复用

补丁扩展现有 FocusEmulator，只处理联机会话中的鼠标事件。玩家归属来自 Brotato Online 的公开 API；焦点、按住确认、按钮切换和具体菜单操作复用原版 FocusEmulator 与 Online 已有的按钮信号和同步拦截。补丁不另行实现购买、升级、奖励或网络协议。

商店恢复现有隐藏按钮，并为前置客户端的战利品禁用补接原有松开取消回调；武器选择保留同一已确认武器的重复同步焦点。客户端鼠标确认具体武器时，会等待前置原有房主焦点回执，避免未安装补丁的房主因延后处理焦点而取消选择。下拉菜单的命中计算复用引擎原生处理，选择仍调用原 FE 确认。

不重分发游戏、Online 或其他第三方 mod 的文件。本补丁原创代码为 MIT；[Brotato Online](https://github.com/xx666zz/BrotatoOnline) 为 GPL-3.0，游戏与前置分别遵循自己的条款。构建和隔离测试复用本项目现有 MIT 辅助脚本。

## 构建与验证

```powershell
python tools/build_mouse_ui.py
python tools/run_mouse_ui_tests.py --game-dir 'D:/Program Files (x86)/Steam/steamapps/common/Brotato' --case all
```

测试只使用本机拥有的游戏和已安装的 Online ZIP，私有资源保存在 `.local/mouse-ui-tests/`，测试存档使用 `BrotatoMouseUITests-*`。它们不会包含在安装包或源码包中。

若更新游戏 / Online 后发生异常，停用本补丁并重启，核对版本和日志；新版本的界面及同步入口可能变化，需要重新验证。
