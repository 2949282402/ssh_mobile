package telemetry

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// decodeStrictJSON decodes one complete JSON object and rejects unknown fields
// at every object level. HTTP payloads are contract inputs, so silently
// accepting a misspelled field would make the sender believe it was enforced
// when the server actually ignored it.
func decodeStrictJSON(r io.Reader, dst any) error {
	decoder := json.NewDecoder(r)
	decoder.UseNumber()
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return err
	}

	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '{' {
		return errors.New("JSON object required")
	}
	objectDecoder := json.NewDecoder(bytes.NewReader(raw))
	objectDecoder.DisallowUnknownFields()
	objectDecoder.UseNumber()
	if err := objectDecoder.Decode(dst); err != nil {
		return err
	}
	return nil
}
