struct Conn {
mut:
	fd int
	p  &int = unsafe { nil }
}

fn main() {
	mut c := Conn{
		fd: 1
	}
	c.p = &c.fd
	mut d := c
	d.fd = 2
	// unsafe: reads through the copied pointer to show whose field it still points at.
	through := unsafe { *d.p }
	println('copy.fd=${d.fd} value behind copy.p=${through} same address as original field: ${voidptr(d.p) == voidptr(&c.fd)}')
}
