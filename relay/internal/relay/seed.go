// One-time enrollment seeding for migrating a memory-only deployment to MySQL.

package relay

import (
	"context"
	"fmt"
)

// SeedEnrollments idempotently upserts enrollments from a one-time migration
// dump. Identity conflicts (a different public key for an already-enrolled
// device) are skipped rather than overwritten, so re-running a seed is safe.
// Any other failure (including a full enrollment store) aborts the seed so an
// operator cannot silently lose devices. Used by the relay binary's
// -seed-enrollments flag before serving.
func (s *Server) SeedEnrollments(ctx context.Context, devices []EnrolledDevice) error {
	for i := range devices {
		device := &devices[i]
		unlock, locked := s.lockDeviceContext(ctx, device.DeviceID)
		if !locked {
			return ctx.Err()
		}
		result, err := s.store.PutEnrollment(ctx, device)
		unlock()
		if err != nil {
			return err
		}
		if result != enrollmentOK && result != enrollmentIdentityConflict {
			return fmt.Errorf("seed device %q: unexpected result %v", device.DeviceID, result)
		}
	}
	return nil
}
