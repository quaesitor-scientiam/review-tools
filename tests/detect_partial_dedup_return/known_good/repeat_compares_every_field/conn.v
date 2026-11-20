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

// handle treats a frame as a repeat only when every field it applies matches a known entry, so a
// raised retire_prior_to still retires the older IDs.
fn (mut c Conn) handle(f Frame) {
	for e in c.entries {
		if f.seq == e.seq && f.cid == e.cid && f.retire_prior_to == e.retire_prior_to {
			return
		}
	}
	c.entries << f
	if f.retire_prior_to > c.retire {
		c.retire = f.retire_prior_to
	}
}
