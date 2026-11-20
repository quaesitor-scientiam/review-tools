module main

struct Frame {
	seq             u64
	cid             []u8
	retire_prior_to u64
}

struct Conn {
mut:
	entries []Frame
	retire  u64
}

// handle treats a frame with a known sequence number and connection ID as a repeat, so a repeat
// that raises retire_prior_to never retires the older IDs.
fn (mut c Conn) handle(f Frame) {
	for e in c.entries {
		if f.seq == e.seq && f.cid == e.cid {
			return
		}
	}
	c.entries << f
	if f.retire_prior_to > c.retire {
		c.retire = f.retire_prior_to
	}
}
