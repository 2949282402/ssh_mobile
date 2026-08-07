// v1 Relay 管理控制台交互；本文件不承载设备数据面或协议兼容逻辑。

var statsTimer = null;

/** 检查管理员会话并切换控制台视图。 */
function checkAuth() {
  fetch('/api/auth-status')
    .then(function(res) { return res.json(); })
    .then(function(data) {
      var loginModal = document.getElementById('loginModal');
      var userSection = document.getElementById('userSection');

      if (!data.authenticated) {
        loginModal.style.display = 'flex';
        userSection.style.display = 'none';
        if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
      } else {
        loginModal.style.display = 'none';
        userSection.style.display = 'flex';
        document.getElementById('adminUsername').innerText = data.username || '';
        updateStats();
        if (!statsTimer) {
          statsTimer = setInterval(updateStats, 3000);
        }
      }
    })
    .catch(function(err) {
      console.error('Auth status check failed:', err);
    });
}

/** 提交管理员登录表单并显示安全错误诊断。 */
function handleLogin(e) {
  e.preventDefault();
  var u = document.getElementById('loginUser').value.trim();
  var p = document.getElementById('loginPass').value;
  var errDiv = document.getElementById('loginError');
  errDiv.style.display = 'none';

  fetch('/api/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: u, password: p })
  })
  .then(function(res) {
    return res.json().then(function(data) {
      if (!res.ok) {
        throw new Error(data.message || '登录失败');
      }
      return data;
    });
  })
  .then(function() {
    checkAuth();
  })
  .catch(function(err) {
    errDiv.innerText = err.message;
    errDiv.style.display = 'block';
  });
}

/** 请求注销当前管理员会话。 */
function logout() {
  if (!confirm('确定要退出登录吗？')) return;
  fetch('/api/logout', { method: 'POST' })
    .then(function() {
      checkAuth();
    });
}

/** 拉取控制台统计和设备列表。 */
function updateStats() {
  fetch('/api/stats')
    .then(function(res) {
      if (res.status === 401 || res.status === 403) {
        checkAuth();
        return null;
      }
      return res.json();
    })
    .then(function(data) {
      if (!data) return;
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
      tbody.replaceChildren();
      if (!data.enrolled_devices || data.enrolled_devices.length === 0) {
        var emptyRow = document.createElement('tr');
        var emptyCell = document.createElement('td');
        emptyCell.colSpan = 5;
        emptyCell.className = 'empty-state';
        emptyCell.textContent = '暂无已注册设备';
        emptyRow.appendChild(emptyCell);
        tbody.appendChild(emptyRow);
      } else {
        for (var j = 0; j < data.enrolled_devices.length; j++) {
          var dev = data.enrolled_devices[j];
          var isOnline = activeDeviceSet[dev.device_id];
          var enrolledTime = dev.enrolled_at ? new Date(dev.enrolled_at).toLocaleString() : '-';

          var row = document.createElement('tr');
          row.appendChild(textCell(dev.device_id, 'mono'));
          row.appendChild(textCell(dev.platform || 'unknown'));
          row.appendChild(textCell(enrolledTime));

          var statusCell = document.createElement('td');
          var statusBadge = document.createElement('span');
          statusBadge.className = isOnline ? 'badge-online' : 'badge-offline';
          statusBadge.textContent = isOnline ? '● 在线 (Online)' : '○ 离线 (Offline)';
          statusCell.appendChild(statusBadge);
          row.appendChild(statusCell);

          var actionCell = document.createElement('td');
          var revokeButton = document.createElement('button');
          revokeButton.className = 'btn btn-danger compact-action';
          revokeButton.textContent = '撤销注册';
          revokeButton.addEventListener('click', revokeDevice.bind(null, dev.device_id));
          actionCell.appendChild(revokeButton);
          row.appendChild(actionCell);
          tbody.appendChild(row);
        }
      }
    })
    .catch(function(err) {
      console.error('Failed to fetch stats:', err);
    });
}

/** 创建不使用动态 HTML 的文本单元格。 */
function textCell(value, className) {
  var cell = document.createElement('td');
  if (className) cell.className = className;
  cell.textContent = value == null ? '' : String(value);
  return cell;
}

/** 将当前 enrollment token 复制到系统剪贴板。 */
function copyToken() {
  var token = document.getElementById('tokenInput').value;
  if (!token) return;
  navigator.clipboard.writeText(token).then(function() {
    alert('Enrollment Token 已成功复制到剪贴板！');
  });
}

/** 请求轮换设备 enrollment token。 */
function rotateToken() {
  if (!confirm('确定要重置并重新生成 Enrollment Token 吗？已重置后新设备注册需要使用新 Token。')) return;
  fetch('/api/token/rotate', { method: 'POST' })
    .then(function(res) {
      if (res.status === 401 || res.status === 403) {
        checkAuth();
        return null;
      }
      return res.json().then(function(data) {
        if (!res.ok) throw new Error(data.message || 'Token 轮换失败');
        return data;
      });
    })
    .then(function(data) {
      if (!data) return;
      document.getElementById('tokenInput').value = data.enrollment_token;
      alert('Token 已成功重新生成：' + data.enrollment_token);
    })
    .catch(function(err) {
      alert(err.message);
    });
}

/** 请求撤销指定设备并刷新设备列表。 */
function revokeDevice(deviceId) {
  if (!confirm('确定要撤销并解绑设备 [' + deviceId + '] 吗？撤销后该设备当前连接将被切断。')) return;
  fetch('/api/devices/revoke', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_id: deviceId })
  })
  .then(function(res) {
    if (res.status === 401 || res.status === 403) {
      checkAuth();
      return null;
    }
    return res.json().then(function(data) {
      if (!res.ok) throw new Error(data.message || '设备撤销失败');
      return data;
    });
  })
  .then(function(data) {
    if (!data) return;
    updateStats();
  })
  .catch(function(err) {
    alert(err.message);
  });
}

document.getElementById('loginForm').addEventListener('submit', handleLogin);
document.getElementById('logoutButton').addEventListener('click', logout);
document.getElementById('copyTokenButton').addEventListener('click', copyToken);
document.getElementById('rotateTokenButton').addEventListener('click', rotateToken);

checkAuth();
