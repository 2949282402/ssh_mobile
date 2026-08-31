//! Live Relay identity -> telemetry credential -> ingest coverage.
//!
//! The shell E2E launchers own only deployment setup. This test owns the
//! device identity and keeps the one-time telemetry secret in process memory,
//! so an administrator session or a script never has to read or copy it.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

type HmacSha256 = Hmac<Sha256>;

const TEST_TIMEOUT: Duration = Duration::from_secs(20);
const TELEMETRY_ENROLL_PATH: &str = "/api/v1/telemetry/enroll";
const TELEMETRY_AUTH_PATH: &str = "/api/v1/telemetry/auth";
const TELEMETRY_INGEST_PATH: &str = "/api/v1/telemetry/ingest";
const ADMIN_TELEMETRY_REGISTRATION_PATH: &str = "/api/admin/v1/telemetry/devices";

struct Identity {
    device_id: String,
    signing_seed: [u8; 32],
    public_key: [u8; 32],
    relay_credential: String,
}

impl Identity {
    fn new(device_id: String) -> Self {
        let mut signing_seed = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut signing_seed);
        let signing_key = SigningKey::from_bytes(&signing_seed);
        Self {
            device_id,
            signing_seed,
            public_key: signing_key.verifying_key().to_bytes(),
            relay_credential: String::new(),
        }
    }

    fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.signing_seed)
    }
}

#[tokio::test]
#[ignore = "requires the isolated Caddy -> Go Relay deployment"]
async fn device_identity_enrolls_telemetry_and_refreshes_after_expired_token() {
    let base_url = std::env::var("CLIENT_BACKEND_E2E_BASE_URL")
        .expect("CLIENT_BACKEND_E2E_BASE_URL must point at the Caddy HTTP origin");
    let enrollment_token = std::env::var("RELAY_ENROLLMENT_TOKEN")
        .expect("RELAY_ENROLLMENT_TOKEN must be supplied by client_backend_e2e.sh");

    wait_for_telemetry_policy(&base_url)
        .await
        .expect("telemetry service should become ready before enrollment");

    let device_id = format!(
        "{}e2e-telemetry-{}",
        std::env::var("CLIENT_BACKEND_E2E_DEVICE_PREFIX").unwrap_or_default(),
        unique_suffix()
    );
    let mut identity = Identity::new(device_id.clone());
    identity.relay_credential = enroll_relay(&base_url, &enrollment_token, &identity)
        .await
        .expect("Relay device enrollment should succeed");

    // The retired administrator minting endpoint must not exist. In
    // particular, no admin login or secret-bearing response is part of this
    // device flow.
    let retired_body = json!({"deviceId": identity.device_id}).to_string();
    let (status, _) = http_json(
        &base_url,
        ADMIN_TELEMETRY_REGISTRATION_PATH,
        "POST",
        &retired_body,
    )
    .await
    .expect("retired admin telemetry route should be reachable through Caddy");
    assert_eq!(
        status, 404,
        "admin telemetry secret minting must be removed"
    );

    // Public enrollment is proof-bound to the same Relay credential and
    // Ed25519 identity that was just enrolled. The response secret never
    // leaves this process and is not printed by any helper.
    let telemetry_secret = enroll_telemetry(&base_url, &identity)
        .await
        .expect("proof-bound telemetry enrollment should succeed");
    assert_eq!(telemetry_secret.len(), 64);
    assert!(hex::decode(&telemetry_secret).is_ok());

    let mut token = authenticate_telemetry(&base_url, &identity.device_id, &telemetry_secret)
        .await
        .expect("telemetry HMAC authentication should issue a token");
    let event_id = e2e_telemetry_event_id();
    let ingest_body = telemetry_event(&identity.device_id, &event_id);

    assert_eq!(
        ingest(&base_url, &identity.device_id, &token, &ingest_body).await,
        200,
        "telemetry ingest should accept a proof-authenticated token"
    );

    // A repeat with a durable event id is idempotent, proving the response is
    // from the telemetry pipeline rather than merely an HTTP success page.
    assert_eq!(
        ingest_status(&base_url, &identity.device_id, &token, &ingest_body).await,
        "already_seen",
        "telemetry ingest should preserve event idempotency"
    );

    // Simulate natural bearer expiry at the HTTP boundary. The telemetry
    // client handles this 401 by clearing the cached token, authenticating
    // with its retained one-time secret, and retrying the same batch.
    token = "0.expired".to_string();
    assert_eq!(
        ingest_with_automatic_refresh(
            &base_url,
            &identity.device_id,
            &telemetry_secret,
            &mut token,
            &ingest_body,
        )
        .await,
        Ok("already_seen".to_string()),
        "expired bearer should receive 401, automatically re-authenticate, and retry"
    );
}

async fn enroll_relay(
    base_url: &str,
    enrollment_token: &str,
    identity: &Identity,
) -> Result<String, String> {
    let body = json!({
        "device_id": identity.device_id,
        "public_key": URL_SAFE_NO_PAD.encode(identity.public_key),
        "protocol_version": 2,
        "platform": "rust-telemetry-e2e",
        "enrollment_token": enrollment_token,
    })
    .to_string();
    let (status, response) = http_json(base_url, "/v2/devices/enroll", "POST", &body).await?;
    if status != 200 {
        return Err(format!("Relay enrollment returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(&response)
        .map_err(|_| "Relay enrollment response was not JSON".to_string())?;
    let credential = payload
        .get("credential")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Relay enrollment response omitted credential".to_string())?;
    if payload.get("protocol_version").and_then(Value::as_u64) != Some(2) {
        return Err("Relay enrollment response used an unexpected protocol".to_string());
    }
    Ok(credential.to_string())
}

async fn enroll_telemetry(base_url: &str, identity: &Identity) -> Result<String, String> {
    let nonce = random_nonce();
    let timestamp = unix_seconds()?;
    let transcript = format!("POST\n{TELEMETRY_ENROLL_PATH}\n{timestamp}\n{nonce}");
    let signature = URL_SAFE_NO_PAD.encode(
        identity
            .signing_key()
            .sign(transcript.as_bytes())
            .to_bytes(),
    );
    let body = json!({
        "deviceId": identity.device_id,
        "relayCredential": identity.relay_credential,
        "publicKey": URL_SAFE_NO_PAD.encode(identity.public_key),
        "timestamp": timestamp,
        "nonce": nonce,
        "signature": signature,
    })
    .to_string();
    let (status, response) = http_json(base_url, TELEMETRY_ENROLL_PATH, "POST", &body).await?;
    if status != 201 {
        return Err(format!("telemetry enrollment returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(&response)
        .map_err(|_| "telemetry enrollment response was not JSON".to_string())?;
    if payload.get("deviceId").and_then(Value::as_str) != Some(&identity.device_id) {
        return Err("telemetry enrollment response used an unexpected device".to_string());
    }
    payload
        .get("secret")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64 && hex::decode(value).is_ok())
        .map(str::to_string)
        .ok_or_else(|| "telemetry enrollment response omitted a valid credential".to_string())
}

async fn authenticate_telemetry(
    base_url: &str,
    device_id: &str,
    secret: &str,
) -> Result<String, String> {
    let exp_epoch = unix_seconds()? + 60;
    let derived_key = Sha256::digest(secret.as_bytes());
    let derived_key_hex = hex::encode(derived_key);
    let message = format!("telemetry:auth:{device_id}:{exp_epoch}");
    let mut mac = HmacSha256::new_from_slice(derived_key_hex.as_bytes())
        .map_err(|_| "telemetry proof key could not be constructed".to_string())?;
    mac.update(message.as_bytes());
    let proof = hex::encode(mac.finalize().into_bytes());
    let body = json!({
        "deviceId": device_id,
        "proof": proof,
        "expEpoch": exp_epoch,
    })
    .to_string();
    let (status, response) = http_json(base_url, TELEMETRY_AUTH_PATH, "POST", &body).await?;
    if status != 200 {
        return Err(format!("telemetry authentication returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(&response)
        .map_err(|_| "telemetry authentication response was not JSON".to_string())?;
    payload
        .get("token")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "telemetry authentication response omitted token".to_string())
}

async fn wait_for_telemetry_policy(base_url: &str) -> Result<(), String> {
    for _ in 0..90 {
        if let Ok((status, _)) = http_json(base_url, "/api/v1/telemetry/policy", "GET", "").await {
            if status == 200 {
                return Ok(());
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err("telemetry policy did not become ready".to_string())
}

fn telemetry_event(device_id: &str, event_id: &str) -> String {
    json!({
        "records": [{
            "eventId": event_id,
            "recordType": "analytics",
            "eventName": "ssh.session.started",
            "eventVersion": 1,
            "deviceId": device_id,
            "sessionId": format!(
                "{}e2e-telemetry-session",
                std::env::var("CLIENT_BACKEND_E2E_DEVICE_PREFIX").unwrap_or_default()
            ),
            "traceId": format!(
                "{}e2e-telemetry-trace",
                std::env::var("CLIENT_BACKEND_E2E_DEVICE_PREFIX").unwrap_or_default()
            ),
            "occurredAt": rfc3339_now(),
            "feature": "ssh",
            "severity": "info",
            "appVersion": "ci",
            "buildNumber": "ci",
            "platform": "rust",
            "properties": {
                "session_type": "interactive",
                "auth_method": "key"
            }
        }]
    })
    .to_string()
}

fn e2e_telemetry_event_id() -> String {
    let suffix = unique_suffix();
    let prefix = std::env::var("CLIENT_BACKEND_E2E_DEVICE_PREFIX").unwrap_or_default();
    if prefix.is_empty() {
        return format!("e2e-telemetry-event-{suffix}");
    }
    // Keep the prefixed online identifier within the shared 64-byte event_id
    // contract while retaining the complete run prefix for cleanup/audit
    // filtering. Sixteen hex characters provide ample per-run uniqueness.
    format!("{prefix}telemetry-{}", &suffix[..16])
}

async fn ingest(base_url: &str, device_id: &str, token: &str, body: &str) -> u16 {
    ingest_once(base_url, device_id, token, body)
        .await
        .expect("telemetry ingest should receive an HTTP response")
        .0
}

async fn ingest_once(
    base_url: &str,
    device_id: &str,
    token: &str,
    body: &str,
) -> Result<(u16, Vec<u8>), String> {
    http_json_with_headers(
        base_url,
        TELEMETRY_INGEST_PATH,
        "POST",
        body,
        &[
            ("Authorization", format!("Bearer {token}")),
            ("X-Device-Id", device_id.to_string()),
        ],
    )
    .await
}

async fn ingest_status(base_url: &str, device_id: &str, token: &str, body: &str) -> String {
    let (status, response) = ingest_once(base_url, device_id, token, body)
        .await
        .expect("telemetry ingest should receive an HTTP response");
    ingest_result(status, &response).expect("telemetry ingest response should contain a status")
}

async fn ingest_with_automatic_refresh(
    base_url: &str,
    device_id: &str,
    secret: &str,
    token: &mut String,
    body: &str,
) -> Result<String, String> {
    let (status, response) = ingest_once(base_url, device_id, token, body).await?;
    if status == 200 {
        return ingest_result(status, &response);
    }
    if status != 401 {
        return Err(format!(
            "telemetry ingest returned HTTP {status}, expected 401"
        ));
    }

    // This mirrors the production transport's 401 recovery contract: discard
    // the bearer, prove possession of the retained one-time secret, and retry
    // the same batch exactly once.
    *token = authenticate_telemetry(base_url, device_id, secret).await?;
    let (retry_status, retry_response) = ingest_once(base_url, device_id, token, body).await?;
    ingest_result(retry_status, &retry_response)
}

fn ingest_result(status: u16, response: &[u8]) -> Result<String, String> {
    if status != 200 {
        return Err(format!("telemetry ingest returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(response)
        .map_err(|_| "telemetry ingest response should be JSON".to_string())?;
    payload["results"][0]["status"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "telemetry ingest response should contain a status".to_string())
}

async fn http_json(
    base_url: &str,
    path: &str,
    method: &str,
    body: &str,
) -> Result<(u16, Vec<u8>), String> {
    http_json_with_headers(base_url, path, method, body, &[]).await
}

async fn http_json_with_headers(
    base_url: &str,
    path: &str,
    method: &str,
    body: &str,
    headers: &[(&str, String)],
) -> Result<(u16, Vec<u8>), String> {
    let origin = url::Url::parse(base_url).map_err(|error| format!("invalid base URL: {error}"))?;
    if !matches!(origin.path(), "" | "/") || origin.query().is_some() || origin.fragment().is_some()
    {
        return Err("live telemetry E2E requires an origin without a path".to_string());
    }
    let mut target = origin;
    target.set_path(path);
    target.set_query(None);
    target.set_fragment(None);

    let mut command = Command::new("curl");
    command
        .arg("--silent")
        .arg("--show-error")
        .arg("--noproxy")
        .arg("*")
        .arg("--max-time")
        .arg("20")
        .arg("--request")
        .arg(method)
        .arg("--header")
        .arg("Accept: application/json")
        .arg("--header")
        .arg("Content-Type: application/json")
        .arg("--data-binary")
        .arg("@-")
        .arg("--write-out")
        .arg("\n__SSH_MOBILE_TELEMETRY_STATUS__%{http_code}")
        .arg(target.as_str())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (name, value) in headers {
        command.arg("--header").arg(format!("{name}: {value}"));
    }
    if let Ok(ca_file) = std::env::var("CLIENT_BACKEND_E2E_CA_FILE") {
        if !ca_file.trim().is_empty() {
            command.arg("--cacert").arg(ca_file);
        }
    }

    let mut child = command
        .spawn()
        .map_err(|error| format!("start curl for telemetry E2E: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(body.as_bytes())
            .await
            .map_err(|error| format!("write telemetry E2E body: {error}"))?;
    }
    let output = tokio::time::timeout(TEST_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "curl telemetry E2E request timed out".to_string())?
        .map_err(|error| format!("read curl telemetry E2E result: {error}"))?;
    let marker = b"\n__SSH_MOBILE_TELEMETRY_STATUS__";
    let marker_start = output
        .stdout
        .windows(marker.len())
        .rposition(|window| window == marker)
        .ok_or_else(|| "curl telemetry E2E response omitted HTTP status".to_string())?;
    let status = std::str::from_utf8(&output.stdout[marker_start + marker.len()..])
        .map_err(|_| "curl telemetry E2E status was not ASCII".to_string())?
        .trim()
        .parse::<u16>()
        .map_err(|_| "curl telemetry E2E status was not numeric".to_string())?;
    if !output.status.success() {
        return Err(format!("curl telemetry E2E failed with HTTP {status}"));
    }
    Ok((status, output.stdout[..marker_start].to_vec()))
}

fn unix_seconds() -> Result<i64, String> {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("system clock precedes Unix epoch: {error}"))?
            .as_secs(),
    )
    .map_err(|_| "system clock exceeds signed Unix seconds".to_string())
}

fn random_nonce() -> String {
    let mut nonce = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    URL_SAFE_NO_PAD.encode(nonce)
}

fn unique_suffix() -> String {
    let mut suffix = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut suffix);
    hex::encode(suffix)
}

fn rfc3339_now() -> String {
    let seconds = unix_seconds().unwrap_or(0);
    let days = seconds.div_euclid(86_400);
    let day_seconds = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = day_seconds / 3_600;
    let minute = (day_seconds % 3_600) / 60;
    let second = day_seconds % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

// Howard Hinnant's proleptic Gregorian conversion, kept local so this
// test-only target does not add a date/time dependency to the SDK.
fn civil_from_days(days_since_epoch: i64) -> (i64, i64, i64) {
    let adjusted = days_since_epoch + internals::DAYS_TO_CIVIL_EPOCH;
    let era = if adjusted >= 0 {
        adjusted / 146_097
    } else {
        (adjusted - 146_096) / 146_097
    };
    let day_of_era = adjusted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    (year + if month <= 2 { 1 } else { 0 }, month, day)
}

mod internals {
    // 1970-01-01 is day 719468 in the civil algorithm's epoch.
    pub const DAYS_TO_CIVIL_EPOCH: i64 = 719_468;
}
