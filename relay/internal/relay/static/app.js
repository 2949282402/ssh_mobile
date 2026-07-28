var statsTimer = null;

function checkAuth() {
  fetch('/api/auth-status')
    .then(function(res) { return res.json(); })
    .then(function(data) {
      var loginModal = document.getElementById('loginModal');
      var changePasswordModal = document.getElementById('changePasswordModal');
      var userSection = document.getElementById('userSection');

      if (!data.authenticated) {
        loginModal.style.display = 'flex';
        changePasswordModal.style.display = 'none';
        userSection.style.display = 'none';
        if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
      } else if (data.must_change_password) {
        loginModal.style.display = 'none';
        changePasswordModal.style.display = 'flex';
        userSection.style.display = 'flex';
        document.getElementById('adminUsername').innerText = data.username || 'hejulian';
        if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
      } else {
        loginModal.style.display = 'none';
        changePasswordModal.style.display = 'none';
        userSection.style.display = 'flex';
        document.getElementById('adminUsername').innerText = data.username || 'hejulian';
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
        throw new Error(data.error || '登录失败');
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

function openChangePasswordModal() {
  document.getElementById('changePassError').style.display = 'none';
  document.getElementById('changePasswordModal').style.display = 'flex';
}

function handleChangePassword(e) {
  e.preventDefault();
  var oldPass = document.getElementById('oldPass').value;
  var newPass = document.getElementById('newPass').value;
  var confirmPass = document.getElementById('confirmPass').value;
  var errDiv = document.getElementById('changePassError');
  errDiv.style.display = 'none';

  if (newPass !== confirmPass) {
    errDiv.innerText = '两次输入的新密码不一致！';
    errDiv.style.display = 'block';
    return;
  }

  fetch('/api/change-password', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ old_password: oldPass, new_password: newPass })
  })
  .then(function(res) {
    return res.json().then(function(data) {
      if (!res.ok) {
        throw new Error(data.error || '修改密码失败');
      }
      return data;
    });
  })
  .then(function() {
    alert('密码修改成功！管理面板已解锁。');
    checkAuth();
  })
  .catch(function(err) {
    errDiv.innerText = err.message;
    errDiv.style.display = 'block';
  });
}

function logout() {
  if (!confirm('确定要退出登录吗？')) return;
  fetch('/api/logout', { method: 'POST' })
    .then(function() {
      checkAuth();
    });
}

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
    .then(function(res) {
      if (res.status === 401 || res.status === 403) {
        checkAuth();
        return null;
      }
      return res.json();
    })
    .then(function(data) {
      if (!data) return;
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
  .then(function(res) {
    if (res.status === 401 || res.status === 403) {
      checkAuth();
      return null;
    }
    return res.json();
  })
  .then(function(data) {
    if (!data) return;
    updateStats();
  });
}

// Start auth check on page load
checkAuth();
