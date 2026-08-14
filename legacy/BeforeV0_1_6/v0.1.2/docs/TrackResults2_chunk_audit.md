# TrackResults2 分块逻辑审计报告

**日期：** 2026-07-30  
**分支：** `mexBaseFast`（修复主战场）+ `master`（同步分块修复）  
**关联现象：** 100 s 单星冒烟图横轴停在 ~60 s、`cur_state`/`trk_state` 在 60 s 掉 0、LONG%≈60%，而过程日志跑满 100 s。

---

## 1. 设计意图

跟踪结果按块环形缓冲，避免一次性预分配过长数组：

| 概念 | 含义 |
|------|------|
| `Nsize` | 块容量（默认 `min(msToProcess, 60000)`） |
| `TRii = rem(loopCnt-1,Nsize)+1` | 块内写指针 |
| `save()` | 满块落盘 `Trk_Prn_XX_kkk.mat` 并清空缓冲 |
| `partsave(idx)` | 末块不足容量时截断后落盘 |
| `copyFROM` | 将各块拼进 `finalTRes`（长度 = `msToProcess`） |

在线跟踪（`loopCnt` 到 `msToProcess`）与磁盘 final 拼接是两条路径；**过程打印正常 ≠ final 数组正确**。

---

## 2. 问题清单（1–6）与根因

### BUG-1 — `partsave` 截断后不更新 `Nsize`（致命）

**现象**

- 第二块物理长度 `length(I_P)=40000`，`Nsize` 仍为 `60000`。
- `copyFROM` 用 `Len_r == other_obj.Nsize` 区分 1 ms 字段与 CNo 字段。

**后果**

- 尾块 1 ms 数据被当成慢速字段，写入 `I_start_CNo` 一带，**覆盖前块中段**。
- `final` 的 `60001:end` 仍为默认值（`cur_state=false`、`trk_state=0`）。
- 图上看起来像 60 s 后“退出 LONG / 空闲”。

**修改**

- `partsave` 截断后：`obj.Nsize = idx`（有效样本数）。
- `copyFROM` 改为**字段表分类**（1 ms / CNo），不再用 `Len_r == Nsize`。
- `I_start` 推进：`I_start = I_start + length(tmpTrk.I_P)`。

---

### BUG-2 — `save` / `copyFROM` 裸引用 `settings`（致命）

**现象**

```matlab
function succeed = save(obj)   % 无 settings 参数
    cnoInt = 1e3;
    if isfield(settings,'CNoInterval')  % 未定义
```

**后果**

- 方法作用域无 `settings`：应报错或依赖不可复现环境。
- 默认 `cnoInt=1e3` 与工程 `CNoInterval=200` 不一致 → CNo 数组长度错误 / 写穿风险。

**修改**

- 构造时把 `CNoInterval` 存成 **`obj.CNoInterval`**。
- `save` / `copyFROM` / `partsave` / 清空缓冲一律用 `obj.CNoInterval`。
- `partsave(obj, settings, idx)` 中 settings 可选，仅兼容旧调用。

---

### BUG-3 — CNo 下标与数组长度契约混乱（高）

**现象**

| 位置 | 行为 |
|------|------|
| 构造 | `nCNo = floor(Nsize/cnoInt)` |
| 跟踪写 | `CNoCnt = TRii/CNoInterval`（依赖整除） |
| `save` 清空 | 默认按 1000 重算 `nCNo` |
| `Calc_CNo_PLD` | 用 `TRii-CNoInterval+1:TRii`，跨块时窗口落到已清空区 |

**后果**

- 块边界附近 C/N0 不可靠。
- `CNoInterval` 非整除 `Nsize` 时下标与长度不一致。

**修改**

- `nCNo = max(1, ceil(Nsize / CNoInterval))`。
- 写侧统一：`CNoCnt = max(1, ceil(TRii / CNoInterval))`。
- 文档约定：CNo 下标为块内第 `ceil(TRii/CNoInterval)` 个慢速点。

---

### BUG-4 — `save()` 清空字段不完整（中高）

**现象**

清空列表有 I/Q、FLL、KF、部分 CNo，**缺少**：

- `Ppre` / `Ppost` / `eta`
- `S4_ori` / `S4_corr` / `S4`

**后果**

- 第二块残留上一块 PB/S4 尾数据。
- 字段长度与 `Nsize` 不一致，加剧 `copyFROM` 误判。

**修改**

- 抽取 `resetBuffers()`，与构造预分配字段集一致，满块 `save` 后调用。

---

### BUG-5 — 尾块 `partsave` 条件恒真（中）

**现象**

```matlab
if rem(loopCnt, trkBuf.Nsize) >= 0  % 永远 true
    partsave(...)
end
```

**后果**

- `msToProcess` 恰为 `Nsize` 整数倍时：`save` 已落满块，再 `partsave` 多写一空/半空文件或打乱 `Svtimes`。
- 逻辑靠副作用“碰巧正确”，不可维护。

**修改**

```matlab
if rem(loopCnt, trkBuf.Nsize) ~= 0
    partsave(settings, TRii);
end
% 满块仅由循环内 save() 负责
```

---

### BUG-6 — `I_start` 用陈旧 `Nsize` 推进（中高）

**现象**

```matlab
I_start = tmpTrk.Nsize + I_start;  % 尾块仍可能 +60000
```

**后果**

- 与 BUG-1 叠加时拼接点错误；修 BUG-1 后若仍用旧 Nsize 也会留空洞。

**修改**

```matlab
I_start = I_start + numel(tmpTrk.I_P);
```

---

### 附带（审查中一并修）

| ID | 问题 | 修改 |
|----|------|------|
| B7 | `copyFROM` 对过大 `I_start` 静默 `min` 到末尾 | 越界则 warning 并返回 |
| B8 | 未写满的 `cur_state=false` 像失锁 | 拼接正确后自然消失；预分配语义在报告中说明 |
| B9 | `writeCNo` 与块边界 | 与 BUG-3 统一 `ceil` 下标 |

---

## 3. 与 100 s 冒烟的对应

| 观察 | 解释 |
|------|------|
| 在线 log 到 100 s | `loopCnt` 完整，环路在跑 |
| final 图 ~60 s | 尾块未拼到 `60001:end`（BUG-1） |
| LONG%≈60% | 仅第一块有效状态 |
| 60 s 状态掉 0 | 预分配空洞，非必然 REACQ |
| ~40 s 载波台阶 | 环路行为，与分块无关 |

---

## 4. 修改文件清单

| 文件 | 分支 | 变更 |
|------|------|------|
| `channelCtrl/TrackResults2.m` | fast + master | CNoInterval 属性；resetBuffers；save/partsave/copyFROM |
| `tracking/tracking2_v6_fix2.m` | fast + master | partsave 条件；I_start；CNoCnt |
| `docs/TrackResults2_chunk_audit.md` | 两分支 | 本报告 |

---

## 5. 验证建议

```matlab
setupPaths
% 可选：build_mex  (mexBaseFast)
smoke = smoke_tracking('acqSatelliteList',41,'msToProcess',100000,'doQuickPlot',false);
tr = smoke.trackResults(1);
assert(numel(tr.I_P) >= 100000 || tr.Nsize >= 100000);
assert(nnz(isfinite(tr.I_P)) > 90000);
assert(mean(tr.cur_state(1:60000)) > 0.5);           % 前 60 s 大量 LONG
assert(any(tr.cur_state(60001:min(end,100000))));     % 后段不应全 false
```

---

## 6. 结论

分块架构可保留；**尾块 `Nsize` 契约 + 裸 `settings` + 恒真 `partsave`** 是引入异常的主因。  
修复后，final 轨迹应覆盖完整 `msToProcess`，60 s 边界不再表现为“假失锁”。

---

## 7. 已落地修改记录

| 分支 | Commit | 内容 |
|------|--------|------|
| `mexBaseFast` | `2686445` | TrackResults2 分块修复 + tracking 调用侧 + 本审计文档 |
| `master` | `b831366` | 同步 TrackResults2 分块修复 + tracking 调用侧 + 本审计文档 |

### 代码改动要点（实现层）

1. **`partsave`**：截断后 `obj.Nsize = idx`；磁盘对象有效长度 = `numel(I_P)`。  
2. **`copyFROM`**：`msFieldNames` / `slowFieldNames` 分类拷贝；`I_start` 与 `numel(src.I_P)` 对齐。  
3. **`save` / `resetBuffers`**：用 `obj.CNoInterval`；清空含 Ppre/Ppost/eta/S4*。  
4. **`ChunkCapacity`**：环缓冲容量与截断后 `Nsize` 分离。  
5. **tracking**：`rem(..., ChunkCapacity)`；尾块仅 `rem ~= 0` 时 `partsave`；`I_start += numel(I_P)`；`CNoCnt = ceil(TRii/CNoInterval)`。

### 单元测试

```
60k full save + 40k partsave + merge → I_P(1..100000) 连续正确，cur_state 全 true
→ CHUNK_UNIT_OK
```
