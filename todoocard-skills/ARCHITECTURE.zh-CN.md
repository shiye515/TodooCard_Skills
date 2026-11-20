# TodooCard Skills v167 架构文档（配对 / 传输协议 / Payload 编码）

本文针对你当前使用的 **v167（raw `0xA7`）** 固件，按“最新能力优先”梳理完整链路。

对应实现文件：
- `todoocard-skills/scripts/prepare_and_send.sh`
- `todoocard-skills/scripts/mac_image_transfer.swift`
- `todoocard-skills/scripts/image_to_payload.swift`
- `todoocard-skills/scripts/quicklz_payload.py`
- `todoocard-skills/scripts/validate_payload.py`

---

## 1. 总体分层

```text
CLI / Agent
  -> prepare_and_send.sh
     -> image_to_payload.swift      (图片 -> 六色位图 -> 控制器位图)
     -> quicklz_payload.py          (控制器位图 -> v167 可用 QuickLZ payload)
     -> validate_payload.py         (格式/解码一致性校验)
     -> mac_image_transfer.swift    (BLE 配对、探测、传输、ACK/续传)
```

核心原则：
- **配对与传图分离**（安全边界）。
- **v167 走 v157+ 可靠传输模型**（窗口化 + checkpoint + 定点修复）。
- **最终成功判据是 `0x05 0x08`**，不是“写完数据”或“连接断开”。

---

## 2. 广播识别与能力位（v167）

从 Manufacturer Data 解析：
- `manufacturerID` 必须 `0x5053`
- `screenType` 必须 `0x134C`
- `firmwareVersion` 当前 `0xA7`
- `capabilityFlags`：
  - `0x01` 需要加密 GATT
  - `0x02` 配对窗口打开
  - `0x08` OTA 恢复模式（拒绝传图）
  - `0x10` Turbo Link 能力

配对按键：v167 使用 5 秒长按触发配对窗口。

---

## 3. 安全配对状态机

`--pair` 路径：

1. 扫描并锁定 **精确 UUID**。
2. 仅当广播 `pairing=open` 时允许连接。
3. 发现服务后读取 `180F/2A19`（Battery Level）。
4. 读取成功即判定系统 bond 成功。

重试策略：
- 仅 `CBErrorDomain code=15` 会重试。
- 退避：0.75s、1.5s，最多 2 次。

拒绝策略：
- `--probe` / `--send` 遇到 `pairing=open` 会拒绝，避免与新配对窗口冲突。

---

## 4. BLE 协议面

服务与特征：
- Service：`FEF0` / `FDF0`
- Control：`FEF1` / `FDF1`
- Data：`FEF2` / `FDF2`

v165+ 诊断通道：
- Service `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1001`
- Char `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1003`

控制命令：
- `0x01` requestBlockSize
- `0x02` requestScreenSize
- `0x03` requestStartTransfer
- `0x05` dataAck（设备上行）

关键状态：
- `0x00` success
- `0x08` transferEnd（最终刷新确认）

---

## 5. v167 传输流程（可靠窗口）

### 5.1 payload 选择

v167 使用自动选择：
- 先准备 QuickLZ v157+ payload 与 RAW controller payload。
- 比较空中传输字节估算（按 240 字节块对齐）。
- 若压缩更小，用 QuickLZ；否则用 RAW。

### 5.2 分块发送

每个数据块格式：
- `4 bytes blockIndex (LE)` + `payloadSlice`

窗口策略：
- 窗口大小：`32 blocks`
- 每窗口发送完成后等待 durable checkpoint ACK
- ACK 返回 index 表示“下一块请求”
  - 等于窗口末：窗口成功
  - 小于窗口末：窗口内修复，从请求索引继续
- checkpoint 超时：只重发窗口末块探测进度
- 最大修复/探测次数：16

### 5.3 结束判据

即使本地认为 payload 已写完，也必须等待 `0x05 0x08`。未收到则失败。

---

## 6. 错误语义与诊断

ACK 错误码：
- `0x01`：格式错误或乱序
- `0x09`：外部 Flash 写失败
- `0x0A`：外部 Flash 回读校验失败

v165+ 失败后读取保留诊断，可定位：
- ACK 是否生成
- 是否被栈接受/拒绝
- 设备请求的块位点
- 最后接收块与上一次状态

---

## 7. 图片编码与方向规范

### 7.1 输入约束

- 文件必须存在
- `<=100MB`
- `<=50MP`

### 7.2 颜色编码

`image_to_payload.swift`：
- 分辨率 `528x792`
- cover 缩放 + 白底
- 六色调色板（黑白黄红蓝绿）
- Floyd-Steinberg 抖动
- 两像素打包 1 字节（4bit + 4bit）

### 7.3 方向与控制器映射

T3 强制 `todoocard-correct`：
- 不允许 `--screen-orientation` 覆盖
- 可选 `--rotate-right-90` 仅用于源图纠偏
- 内部再做固定面板校准与控制器映射得到 `.controller.bin`

---

## 8. QuickLZ v167 可用规范

`quicklz_payload.py`：
- 输入固定 `209088 bytes`（`528*792/2`）
- 按独立 **2KB block** 做 QuickLZ 1.5 level-3
- payload 以 `00 00 00 00` 前缀开头
- 单块压缩无收益时可回退 stored block

`validate_payload.py`：
- 校验结构与块级合法性
- 解码总字节数一致
- 可与 `--expected-raw` 做逐字节对比

---

## 9. 你在 v167 上的推荐实践

1. 先 `--list`，锁定 UUID。  
2. 新 Mac 先 `--pair`，确认加密电池读取成功。  
3. 再 `--probe`，确认链路与诊断可达。  
4. `--input` 先做本地 prepare/validate。  
5. 最后 `--send`，仅以 `0x05 0x08` 作为成功依据。

---

## 10. 兼容备注（非主路径）

若设备低于 v157（`raw < 0x9D`），实现会自动回退 legacy 64-byte stored QuickLZ 格式。该路径仅用于兼容，不是 v167 主流程。
