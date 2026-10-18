module quic

struct Reassembler {
	name string
}

pub fn (r &Reassembler) name() string {
	return r.name
}
