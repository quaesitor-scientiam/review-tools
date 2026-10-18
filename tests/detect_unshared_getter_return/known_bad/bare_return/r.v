module quic

struct Reassembler {
	received []u8
}

pub fn (r &Reassembler) data() []u8 {
	return r.received
}
