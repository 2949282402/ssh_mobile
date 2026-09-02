package admin

import "testing"

func TestRandomBytesHonorsRequestedLength(t *testing.T) {
	for _, size := range []int{0, 1, 32} {
		first := randomBytes(size)
		second := randomBytes(size)
		if len(first) != size || len(second) != size {
			t.Fatalf("randomBytes(%d) lengths = %d/%d, want %d", size, len(first), len(second), size)
		}
		if size > 0 && &first[0] == &second[0] {
			t.Fatalf("randomBytes(%d) returned aliased buffers", size)
		}
	}
}
