# Baidu Map track UI (JSAPI 4.0)

## 为什么双击 index.html 没有底图（图层）？

常见原因（按概率）：

1. **用了 `file://` 打开**  
   百度瓦片服务对本地 `file://` 限制很严，常表现为：能出折线/标记，但**灰底/无街道图层**。  
   **正确做法**：`http://127.0.0.1:端口/index.html`  
   `launchBaiduMapTrack` 会尽量用 Python 起本地服务并打开该地址。

2. **AK 未开通或 Referer 白名单不对**  
   控制台 → 应用 → 浏览器端 AK：  
   - 服务：开启 **JavaScript API**  
   - Referer 白名单：开发阶段可填 `*`，或至少包含  
     `127.0.0.1:*` / `localhost:*`

3. **网络/防火墙拦了** `api.map.baidu.com` 与瓦片域名。

## 手动起本地服务

```text
cd results\smoke\raim_renav_v013
python -m http.server 8765
```

浏览器打开：http://127.0.0.1:8765/index.html

## 坐标

- 轨迹源：WGS84  
- 底图：BD-09  
- 优先 `BMap.Convertor.translate(..., 1, 5)`；失败则离线 WGS84→GCJ02→BD09
