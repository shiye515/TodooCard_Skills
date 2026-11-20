# TodooCard Skills

TodooCard 电子拍立得的开放 Skill。

TodooCard Skills 用于在 macOS 上完成 **v167 最新协议优先** 的安全配对、探测、图片编码与传输。

![TodooCard Skill 头图](assets/todoocard-hero.jpg)

## 适合做什么

- 把 JPG / PNG / HEIC 转换为 TodooCard 可用的六色电子纸 payload。
- 按 **v167 当前协议** 执行传图：2 KB QuickLZ level-3、32 包 checkpoint、按缺块续传。
- 在传输失败时读取 v165+ 保留 ACK 诊断，区分乱序、Flash 写入失败、回读失败。
- 通过实体按键开启的 60 秒窗口完成系统配对，并验证加密 GATT。
- 按设备 UUID 执行安全 probe 与显式 send。

## 安装方式

在 Mac 上打开支持本地 Skills 的 AI Agent 客户端，告诉它：

```text
请安装这个 TodooCard Skills：https://github.com/Sunbelife/TodooCard_Skills
```

安装完成后，重新打开任务或重启客户端，使其重新加载本地 Skills。

## 推荐流程（v167）

1. 扫描附近设备：

   ```bash
   scripts/prepare_and_send.sh --list
   ```

2. 对新 Mac 建立系统配对（需要设备 UUID）：

   ```bash
   scripts/prepare_and_send.sh --pair --device-id UUID
   ```

   v167 固件长按背面按钮 5 秒，正面灯快闪后广播 `pairing=open`。脚本只会在窗口打开时连接并验证加密特征。

3. 配对后探测（验证加密链路与特征可达）：

   ```bash
   scripts/prepare_and_send.sh --probe --device-id UUID
   ```

4. 仅准备与校验 payload（不发送）：

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic
   ```

5. 显式发送：

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic --device-id UUID --send
   ```

## v167 传输契约（最新能力）

- 当前主目标固件：**v167（raw `0xA7`）**。
- 图片协议沿用 v157+ 的可靠传输模型：
  - 优先使用 2 KB 独立 QuickLZ level-3；压缩无收益时自动改用 RAW。
  - 每 32 个数据块等待一次外部 Flash 持久化 checkpoint。
  - checkpoint 返回缺块时仅从请求块续传，不做整包盲重放。
  - 只有收到 `0x05 0x08` 刷新确认才判定成功；断连不等于成功。
- v165+ 失败时可读取保留诊断（ACK 生成/接受/拒绝计数、最后块位点）。
- 能力位 `0x08`（OTA 恢复模式）下拒绝传图。

兼容说明：若设备低于 v157，脚本会自动回退 legacy 兼容 payload（64 字节 stored QuickLZ 流）。

## 固定方向要求

调用方始终提供正向原图。TodooCard/T3 528x792（`0x134C`）由底层 `todoocard-correct` 自动做面板校准，**不允许** `--screen-orientation` 覆盖。

源图横竖方向不对时，可先做源图纠偏：

```bash
--rotate-right-90
```

## 安全提醒

- 发送前必须确认准确 UUID，不要只按设备名。
- 配对成功以“加密特征读取成功”为准，普通 BLE 连接不算。
- `pairing=open` 窗口期间，`--probe` / `--send` 会拒绝执行。
- `--send` 为显式开关，成功后会覆盖当前屏幕画面。
- 不建议发送外部来源 `.bin` 或 `.protocol.qlz`，应由本技能生成并校验。
- 输入限制：100 MB 且 50 megapixels 以内。

## 产品图片

更多产品介绍：[p.todoo.tech](https://p.todoo.tech)

![TodooCard 户外场景](assets/todoocard-outdoor.jpg)

![TodooCard 包装近景](assets/todoocard-box-closeup.jpg)

![TodooCard 键盘场景](assets/todoocard-keyboard.jpg)

![TodooCard 包装场景](assets/todoocard-package.jpg)

![TodooCard 手机背贴场景](assets/todoocard-on-phone.jpg)

![TodooCard 背面](assets/todoocard-back.jpg)

## 购买链接

购买 TodooCard：[wxmpurl.cn/l9UUcyEDIrs](https://wxmpurl.cn/l9UUcyEDIrs)
