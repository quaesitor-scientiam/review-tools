struct Res {
	name string
}

fn (r &Res) free() {
	println('  freed ${r.name}')
}

fn alloc(name string, ok bool) !Res {
	if !ok {
		return error('alloc ${name} failed')
	}
	return Res{
		name: name
	}
}

fn shared_defer() bool {
	a := alloc('shared.a', true) or { return false }
	b := alloc('shared.b', false) or { return false }
	defer {
		a.free()
		b.free()
	}
	return true
}

fn own_defer() bool {
	a := alloc('own.a', true) or { return false }
	defer {
		a.free()
	}
	b := alloc('own.b', false) or { return false }
	defer {
		b.free()
	}
	return true
}

fn main() {
	println('shared_defer:')
	println('  returned ${shared_defer()}')
	println('own_defer:')
	println('  returned ${own_defer()}')
}
