package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"time"
)

var serverStartTime = time.Now()

type statsResponse struct {
	UptimeSeconds   int64      `json:"uptime_seconds"`
	UptimeFormatted string     `json:"uptime_formatted"`
	ActivePeers     int        `json:"active_peers"`
	ActiveSessions  int        `json:"active_sessions"`
	AllocatedMemMB  float64    `json:"allocated_mem_mb"`
	NumGoroutines   int        `json:"num_goroutines"`
	ServerTime      int64      `json:"server_time"`
	Peers           []peerInfo `json:"peers"`
}

type peerInfo struct {
	DeviceID   string `json:"device_id"`
	RemoteAddr string `json:"remote_addr"`
}

func (s *Server) apiStats(w http.ResponseWriter, _ *http.Request) {
	s.hub.mutex.Lock()
	activePeers := len(s.hub.peers)
	activeSessions := len(s.hub.sessions)
	peerList := make([]peerInfo, 0, activePeers)
	for id, p := range s.hub.peers {
		addr := ""
		if p.socket != nil {
			addr = p.socket.RemoteAddr().String()
		}
		peerList = append(peerList, peerInfo{
			DeviceID:   id,
			RemoteAddr: addr,
		})
	}
	s.hub.mutex.Unlock()

	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	uptime := time.Since(serverStartTime)
	days := int(uptime.Hours()) / 24
	hours := int(uptime.Hours()) % 24
	mins := int(uptime.Minutes()) % 60
	secs := int(uptime.Seconds()) % 60
	uptimeStr := ""
	if days > 0 {
		uptimeStr = fmt.Sprintf("%dd ", days)
	}
	uptimeStr += fmt.Sprintf("%02dh %02dm %02ds", hours, mins, secs)

	resp := statsResponse{
		UptimeSeconds:   int64(uptime.Seconds()),
		UptimeFormatted: uptimeStr,
		ActivePeers:     activePeers,
		ActiveSessions:  activeSessions,
		AllocatedMemMB:  float64(m.Alloc) / 1024 / 1024,
		NumGoroutines:   runtime.NumGoroutine(),
		ServerTime:      time.Now().Unix(),
		Peers:           peerList,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(dashboardHTML))
}

const dashboardHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SSH Mobile — 网络控制与中继面板</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0b0f19;
      --card-bg: #151c2c;
      --border: #232d42;
      --primary: #38bdf8;
      --success: #10b981;
      --text: #f8fafc;
      --text-muted: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      padding: 24px;
    }
    .container {
      max-width: 1100px;
      margin: 0 auto;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 32px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--border);
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .brand-icon {
      width: 40px;
      height: 40px;
      background: linear-gradient(135deg, #0284c7, #38bdf8);
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: bold;
      font-size: 20px;
      color: #fff;
      box-shadow: 0 4px 12px rgba(56, 189, 248, 0.3);
    }
    h1 { font-size: 22px; font-weight: 700; }
    .status-badge {
      display: flex;
      align-items: center;
      gap: 8px;
      background: rgba(16, 185, 129, 0.1);
      border: 1px solid var(--success);
      color: var(--success);
      padding: 6px 14px;
      border-radius: 20px;
      font-size: 13px;
      font-weight: 600;
    }
    .pulse {
      width: 8px;
      height: 8px;
      background: var(--success);
      border-radius: 50%;
      box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
      70% { transform: scale(1); box-shadow: 0 0 0 10px rgba(16, 185, 129, 0); }
      100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 20px;
      margin-bottom: 32px;
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      transition: transform 0.2s ease, border-color 0.2s ease;
    }
    .card:hover {
      border-color: #3b82f6;
      transform: translateY(-2px);
    }
    .card-title {
      font-size: 13px;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 8px;
      font-weight: 600;
    }
    .card-value {
      font-size: 28px;
      font-weight: 700;
      color: #fff;
    }
    .card-sub {
      font-size: 12px;
      color: var(--text-muted);
      margin-top: 6px;
    }
    .section-title {
      font-size: 18px;
      font-weight: 600;
      margin-bottom: 16px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 16px;
      overflow: hidden;
      margin-bottom: 32px;
    }
    th, td {
      padding: 14px 18px;
      text-align: left;
    }
    th {
      background: rgba(255, 255, 255, 0.03);
      color: var(--text-muted);
      font-size: 12px;
      font-weight: 600;
      border-bottom: 1px solid var(--border);
    }
    td {
      font-size: 14px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    }
    tr:last-child td { border-bottom: none; }
    .mono { font-family: monospace; color: var(--primary); }
    .empty-state {
      text-align: center;
      padding: 40px;
      color: var(--text-muted);
    }
    .api-list {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
      gap: 16px;
    }
    .api-item {
      background: var(--card-bg);
      border: 1px solid var(--border);
      padding: 16px;
      border-radius: 12px;
    }
    .method {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 700;
      margin-right: 6px;
    }
    .method.post { background: rgba(56, 189, 248, 0.2); color: var(--primary); }
    .method.get { background: rgba(16, 185, 129, 0.2); color: var(--success); }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <div class="brand-icon">&#9889;</div>
        <div>
          <h1>SSH Mobile 控制与中继服务器</h1>
          <p style="font-size: 12px; color: var(--text-muted);">Network Platform Control Plane & WSS Relay</p>
        </div>
      </div>
      <div class="status-badge">
        <div class="pulse"></div>
        <span>服务运行中 (ONLINE)</span>
      </div>
    </header>

    <div class="grid">
      <div class="card">
        <div class="card-title">活动在线设备</div>
        <div class="card-value" id="activePeers">0</div>
        <div class="card-sub">WebSocket 控制连接数</div>
      </div>
      <div class="card">
        <div class="card-title">活动中继会话</div>
        <div class="card-value" id="activeSessions">0</div>
        <div class="card-sub">P2P 备用 Relay 会话数</div>
      </div>
      <div class="card">
        <div class="card-title">服务运行时间</div>
        <div class="card-value" id="uptime" style="font-size: 20px;">00h 00m 00s</div>
        <div class="card-sub">System Uptime</div>
      </div>
      <div class="card">
        <div class="card-title">内存占用</div>
        <div class="card-value" id="memAlloc" style="font-size: 20px;">0 MB</div>
        <div class="card-sub">Go Runtime Alloc</div>
      </div>
    </div>

    <div class="section-title">&#127760; 在线设备列表 (Connected Devices)</div>
    <table>
      <thead>
        <tr>
          <th>设备 ID (Device ID)</th>
          <th>远程网络地址 (Remote Address)</th>
          <th>状态 (Status)</th>
        </tr>
      </thead>
      <tbody id="peerTableBody">
        <tr>
          <td colspan="3" class="empty-state">暂无活动的 WebSocket 设备连接</td>
        </tr>
      </tbody>
    </table>

    <div class="section-title">&#128736; 控制平面 API 接口说明</div>
    <div class="api-list">
      <div class="api-item">
        <div><span class="method post">POST</span> <span class="mono">/v1/devices/enroll</span></div>
        <div style="font-size: 12px; color: var(--text-muted); margin-top: 6px;">设备注册与 Credential 凭据颁发</div>
      </div>
      <div class="api-item">
        <div><span class="method get">GET</span> <span class="mono">/v1/control</span></div>
        <div style="font-size: 12px; color: var(--text-muted); margin-top: 6px;">WebSocket 控制通道（心跳与 Presence 订阅）</div>
      </div>
      <div class="api-item">
        <div><span class="method get">GET</span> <span class="mono">/healthz</span></div>
        <div style="font-size: 12px; color: var(--text-muted); margin-top: 6px;">健康检查接口 (HTTP 204)</div>
      </div>
    </div>
  </div>

  <script>
    function updateStats() {
      fetch('/api/stats')
        .then(function(res) { return res.json(); })
        .then(function(data) {
          document.getElementById('activePeers').innerText = data.active_peers;
          document.getElementById('activeSessions').innerText = data.active_sessions;
          document.getElementById('uptime').innerText = data.uptime_formatted;
          document.getElementById('memAlloc').innerText = data.allocated_mem_mb.toFixed(2) + ' MB';

          var tbody = document.getElementById('peerTableBody');
          if (!data.peers || data.peers.length === 0) {
            tbody.innerHTML = '<tr><td colspan="3" class="empty-state">暂无活动的 WebSocket 设备连接</td></tr>';
          } else {
            var rows = '';
            for (var i = 0; i < data.peers.length; i++) {
              var p = data.peers[i];
              rows += '<tr><td class="mono">' + p.device_id + '</td><td>' + (p.remote_addr || 'WebSocket') + '</td><td><span style="color: var(--success); font-weight: 600;">Connected</span></td></tr>';
            }
            tbody.innerHTML = rows;
          }
        })
        .catch(function(err) {
          console.error('Failed to fetch stats:', err);
        });
    }

    updateStats();
    setInterval(updateStats, 3000);
  </script>
</body>
</html>
`
