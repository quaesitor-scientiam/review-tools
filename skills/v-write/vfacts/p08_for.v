struct P {
mut:
	n int
}

fn main() {
	mut ps := [P{
		n: 1
	}, P{
		n: 2
	}]
	for p in ps {
		mut q := p
		q.n = 100
	}
	println('after for p in ps: ${ps.map(it.n)}')
	for mut p in ps {
		p.n = 100
	}
	println('after for mut p in ps: ${ps.map(it.n)}')
}
