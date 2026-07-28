function updateStats() {
  fetch('/api/stats')
    .then(function(res) { return res.json(); })
    .then(function(data) {
      document.getElementById('activePeers').innerText = data.active_peers;
      document.getElementById('enrolledCount').innerText = data.enrolled_count;
      document.getElementById('uptime').innerText = data.uptime_formatted;
      document.getElementById('memAlloc').innerText = data.allocated_mem_mb.toFixed(2) + ' MB';
      document.getElementById('tokenInput').value = data.enrollment_token || '';

      var activeDeviceSet = {};
      if (data.peers) {
        for (var i = 0; i < data.peers.length; i++) {
          activeDeviceSet[data.peers[i].device_id] = true;
        }
      }

      var tbody = document.getElementById('enrolledTableBody');
      if (!data.enrolled_devices || data.enrolled_devices.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty-state">暂无已注册设备</td></tr>';
      } else {
        var rows = '';
        for (var j = 0; j < data.enrolled_devices.length; j++) {
          var dev = data.enrolled_devices[j];
          var isOnline = activeDeviceSet[dev.device_id];
          var statusBadge = isOnline ? '<span class="badge-online">&#9679; 在线 (Online)</span>' : '<span class="badge-offline">&#9675; 离线 (Offline)</span>';
          var enrolledTime = dev.enrolled_at ? new Date(dev.enrolled_at).toLocaleString() : '-';

          rows += '<tr>' +
            '<td class="mono">' + dev.device_id + '</td>' +
            '<td>' + (dev.platform || 'unknown') + '</td>' +
            '<td>' + enrolledTime + '</td>' +
            '<td>' + statusBadge + '</td>' +
            '<td><button class="btn btn-danger" style="padding: 4px 10px; font-size: 12px;" onclick="revokeDevice(\'' + dev.device_id + '\')">撤销注册</button></td>' +
            '</tr>';
        }
        tbody.innerHTML = rows;
      }
    })
    .catch(function(err) {
      console.error('Failed to fetch stats:', err);
    });
}

function copyToken() {
  var token = document.getElementById('tokenInput').value;
  if (!token) return;
  navigator.clipboard.writeText(token).then(function() {
    alert('Enrollment Token 已成功复制到剪贴板！');
  });
}

function rotateToken() {
  if (!confirm('确定要重置并重新生成 Enrollment Token 吗？已重置后新设备注册需要使用新 Token。')) return;
  fetch('/api/token/rotate', { method: 'POST' })
    .then(function(res) { return res.json(); })
    .then(function(data) {
      document.getElementById('tokenInput').value = data.enrollment_token;
      alert('Token 已成功重新生成：' + data.enrollment_token);
    });
}

function revokeDevice(deviceId) {
  if (!confirm('确定要撤销并解绑设备 [' + deviceId + '] 吗？撤销后该设备当前连接将被切断。')) return;
  fetch('/api/devices/revoke', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_id: deviceId })
  })
  .then(function(res) { return res.json(); })
  .then(function() {
    updateStats();
  });
}

updateStats();
setInterval(updateStats, 3000);
