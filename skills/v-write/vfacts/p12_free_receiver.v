struct Res {
	name string
}

fn (r Res) free() {
	println(r.name)
}

fn main() {
	r := Res{
		name: 'x'
	}
	r.free()
}
