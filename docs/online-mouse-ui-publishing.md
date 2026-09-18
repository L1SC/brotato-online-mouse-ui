# OnlineMouseUI 发布记录

发布日期：2026-09-19。版本：1.0.0。

- 公开源码仓库：[L1SC/brotato-online-mouse-ui](https://github.com/L1SC/brotato-online-mouse-ui)。
- 安装包、源码包与 SHA256：[Release v1.0.0](https://github.com/L1SC/brotato-online-mouse-ui/releases/tag/v1.0.0)。
- 公开创意工坊条目：[Online Mouse UI / 联机鼠标操作补丁](https://steamcommunity.com/sharedfiles/filedetails/?id=3803857989)。
- 工坊必需项：[Brotato Online](https://steamcommunity.com/sharedfiles/filedetails/?id=3741034628)。

源码在独立目录初始化为新仓库，只包含本补丁源码、MIT 许可证、构建和隔离测试辅助脚本及文档，没有公开其他 mod、游戏文件或私有测试日志。

使用游戏自带 GodotWorkshopUtility.exe 的 SteamUGC 接口上传。流程参考 [Blobfish 官方上传器](https://github.com/Blobfish-Games/godot-workshop-utility) 和 [Steamworks ISteamUGC 文档](https://partner.steamgames.com/doc/api/ISteamUGC)。工坊内容目录仅包含已通过完整测试的安装 ZIP，预览图使用实际双人测试的商店截图。

| 核验项目 | 结果 |
| --- | --- |
| 创建 / 提交更新 / 添加必需项 | 均 result=1 |
| 需要补签工坊协议 | false |
| 创建应用 / 消费应用 | 均 1942280 |
| 可见性 / banned | Public (0) / false |
| 标签 | Utilities,GUI |
| 内容文件 | 仅 CoopFix-OnlineMouseUI-1.0.0.zip，13295 字节 |
| 工坊 child dependency | 仅 3741034628，即 Brotato Online |
| 介绍核验 | 服务端完整介绍与本地发布文本一致，无 GitHub 字符串或链接 |
| 实际 Steam 下载 | 成功，ZIP 与发布文件逐字节一致，CRC 通过 |

安装 ZIP SHA256：

```text
844de51a940aaf6d6188d0d39bc211516884b2a71fd91fede2f07e66f224095f
```

源码 ZIP SHA256：

```text
f0639cd1308ce94a943dc8c4d1e23919bca373a3c866846eb5e847253a54bd55
```

发布结果通过实际 SteamUGC 查询与下载核验。游戏功能验证范围继续以 [验证记录](online-mouse-ui-verification.md) 为准；发布成功不扩大 Steam P2P 测试结论。
