fn main() {
	s := 'abc'
	b := s.bytes()
	println('s.len=${s.len} s.bytes().len=${b.len} cap=${b.cap}')
	mut c := b.clone()
	c << u8(0)
	println('copy with a 0 appended: len=${c.len} last=${c[c.len - 1]}')
	raw := [u8(120), 121, 122]
	// unsafe: builds a string over 2 of the 3 bytes and reads the byte after it, to show
	// that such a string has no 0 there.
	view := unsafe { tos(raw.data, 2) }
	after := unsafe { view.str[view.len] }
	println('string view of 2 of 3 bytes: ${view} byte after it=${after}')
}
