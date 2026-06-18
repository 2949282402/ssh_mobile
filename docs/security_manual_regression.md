# SSH Security Manual Regression Checklist

Use this checklist before a security-sensitive release. Record concrete device
and server details, then mark each scenario pass/fail with notes.

## Test Matrix

- Test date:
- App version/build:
- Device and OS:
- Server types:
- Network:
- Tester:

## Host Key and Credentials

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Add a password server with an unknown host key, then cancel trust | Save/connect fails and the key is not persisted |  |  |
| Add the same server and trust the host key | Save/connect succeeds and future connects do not prompt again |  |  |
| Edit host or port | Stored host key fingerprint is cleared and next connect prompts again |  |  |
| Edit only username/password/private key | Stored host key fingerprint is preserved |  |  |
| Server host key changes after trust | Connect is blocked; old fingerprint is not overwritten |  |  |
| Plain SSH connect/disconnect/reconnect | Connects normally and host key policy is enforced every time |  |  |
| tmux connect/attach/disconnect | tmux attach works; unexpected disconnect asks app reconnect instead of background credential reuse |  |  |

## SFTP

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| First SFTP connect to unknown host key | User confirmation is required |  |  |
| Trusted host SFTP browse/download/preview/edit | Works normally |  |  |
| Fingerprint mismatch during SFTP | Operation is blocked |  |  |
| Preview/edit ordinary remote file | Local cache file is encrypted |  |  |
| Preview/edit secret path such as `.env` or `.ssh/id_rsa` | No local cache file is written |  |  |
| Delete a saved connection | SFTP session, remembered path, and cache are cleared |  |  |

## System Admin and Monitor

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Users/Services/Ports/Applications with unknown host key | Confirmation or blocking occurs before SSH execution |  |  |
| Trusted Linux server admin tabs | Data loads for the selected server only |  |  |
| Switch selected admin server | All non-monitor tabs use the shared selected server |  |  |
| Start monitor on untrusted server | Confirmation or blocking occurs before sampling |  |  |
| Trusted Linux/Windows monitor sampling | Sampling works and does not mix selected servers |  |  |

## AI Tools

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| `run_command` reads `~/.ssh/id_rsa`, `/etc/shadow`, `.env`, or environment | Blocked before execution |  |  |
| `run_command` reads logs such as `journalctl` | Requires user approval |  |  |
| SFTP AI read/download ordinary path | Requires user approval |  |  |
| SFTP AI read/download secret path | Blocked before execution |  |  |
| Unknown host key from AI tool path | Not auto-trusted |  |  |
| Fingerprint mismatch from AI tool path | Blocked |  |  |
| WebView reads localhost/private/metadata/file/data/javascript URL | Blocked |  |  |
| WebView page contains password/token/secret form | Text is not returned to AI |  |  |

## Backup, Logs, and Android Background

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Export backup | Passwords, private keys, API keys, and tokens are absent |  |  |
| Import hand-edited backup with credentials/API keys | Credentials are ignored and secure-storage keys are cleared |  |  |
| Import oversized/malformed backup | Import is rejected |  |  |
| Logs include Authorization/Cookie/token/private key/URL query secret | UI and `app.log` show redacted values only |  |  |
| Android background SSH starts | WakeLock/WifiLock are acquired with timeout |  |  |
| Disconnect/stop/failure paths | Locks are released or time out |  |  |
| Background notification default | Server names are hidden unless the setting is enabled |  |  |

## Known Issues

- None recorded.
