package telemetry

import (
	"regexp"
)

// Diagnostic text is untrusted input even when it arrives in a valid
// telemetry envelope. Keep the server boundary at least as strict as the
// client boundary because old clients and third-party senders may not apply
// the client redactor.
const (
	MaxDiagnosticTextLength       = 512
	MaxDiagnosticMessageLength    = MaxDiagnosticTextLength
	MaxDiagnosticStackTraceLength = MaxDiagnosticTextLength
	diagnosticRedactedValue       = "[REDACTED]"
)

var diagnosticPrivacyPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)\b(?:authorization|proxy-authorization)\s*:\s*[^\r\n,;]+`),
	regexp.MustCompile(`(?i)\b(?:cookie|set-cookie)\s*:\s*[^\r\n]+`),
	regexp.MustCompile(`(?i)\b(?:x-api-key|api-key)\s*:\s*[^\r\n,;]+`),
	regexp.MustCompile(`(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+`),
	regexp.MustCompile(`\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b`),
	regexp.MustCompile(`(?i)\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{12,}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{16,}|ghs_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{16,})\b`),
	regexp.MustCompile(`(?i)(["']?(?:[A-Za-z][A-Za-z0-9]*[_-])*(?:password|passwd|pwd|passphrase|private[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|session[_-]?token|auth[_-]?token|token|secret|username|user[_-]?name|user|login|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|path|filename|credentials?|auth(?:orization)?|jwt|bearer)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^,\s}\]]+)`),
	regexp.MustCompile(`(?i)(\b(?:password|passwd|pwd|passphrase|private[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|session[_-]?token|auth[_-]?token|token|secret|username|user[_-]?name|user|login|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|path|filename|credentials?|auth(?:orization)?|jwt|bearer)\s+)("[^"]*"|'[^']*'|[^,\s}\]]+)`),
	regexp.MustCompile(`(?i)([?&](?:password|passwd|pwd|passphrase|username|user[_-]?name|user|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|path|access_token|refresh_token|client_secret|api[_-]?key|x-api-key|token|secret|credentials?|auth(?:orization)?|jwt|bearer)=)[^&#\s]+`),
	regexp.MustCompile(`(?i)\b[a-z][a-z0-9+.-]*://[^\s]+`),
	regexp.MustCompile(`\b[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._:-]{1,255}\b`),
	regexp.MustCompile(`(?:[0-9]{1,3}\.){3}[0-9]{1,3}`),
	regexp.MustCompile(`\b[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}\b`),
	regexp.MustCompile(`(?i)\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}(?::[0-9]{1,5})?\b`),
	regexp.MustCompile(`(?i)\blocalhost(?::[0-9]{1,5})?\b`),
	regexp.MustCompile(`\b[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?:[0-9]{1,5}\b`),
	regexp.MustCompile(`(?i)\b[A-Za-z0-9-]*(?:host|server|node|gateway|router|machine|jumpbox)[A-Za-z0-9-]*\b`),
	regexp.MustCompile(`\bpackage:[^\s)]+`),
	regexp.MustCompile(`(?:[A-Za-z]:\\|\\\\|~[/\\]|\.\.?[/\\]|/)[^\s|;,)]*`),
	regexp.MustCompile(`(?i)\b(?:lib|bin|src|packages|apps|home|tmp|var|etc|users|data)[/\\][^\s|;,)]*`),
	regexp.MustCompile(`\b(?:[A-Za-z0-9_.-]+[/\\])+[^\s|;,)]*`),
	regexp.MustCompile(`(?i)(^|[\s("'=])(?:sudo\s+)?(?:ssh|scp|sftp|curl|wget|nc|netcat|rm|cat|echo|bash|sh|zsh|powershell|cmd(?:\.exe)?|chmod|chown|find|grep|git|python(?:3)?|node(?:js)?|kubectl)\b[^\r\n]*`),
}

func sanitizeEnvelopeForServer(envelope TelemetryEnvelope) TelemetryEnvelope {
	if envelope.Properties != nil {
		properties := make(map[string]any, len(envelope.Properties))
		for key, value := range envelope.Properties {
			if text, ok := value.(string); ok {
				properties[key] = sanitizeDiagnosticText(text, MaxDiagnosticTextLength)
			} else {
				properties[key] = value
			}
		}
		envelope.Properties = properties
	}
	if envelope.Error != nil {
		errorDetail := *envelope.Error
		errorDetail.Message = sanitizeDiagnosticText(errorDetail.Message, MaxDiagnosticMessageLength)
		errorDetail.StackTrace = sanitizeDiagnosticText(errorDetail.StackTrace, MaxDiagnosticStackTraceLength)
		envelope.Error = &errorDetail
	}
	return envelope
}

func sanitizeDiagnosticText(value string, maxBytes int) string {
	if value == "" {
		return value
	}
	text := value
	for _, pattern := range diagnosticPrivacyPatterns {
		text = pattern.ReplaceAllString(text, diagnosticRedactedValue)
	}
	return truncateDiagnosticText(text, maxBytes)
}

func truncateDiagnosticText(value string, maxBytes int) string {
	if value == "" {
		return ""
	}
	if len([]byte(value)) <= maxBytes {
		return value
	}
	runes := []rune(value)
	low, high := 0, len(runes)
	for low < high {
		middle := low + (high-low+1)/2
		if len([]byte(string(runes[:middle]))) <= maxBytes {
			low = middle
		} else {
			high = middle - 1
		}
	}
	return string(runes[:low])
}
