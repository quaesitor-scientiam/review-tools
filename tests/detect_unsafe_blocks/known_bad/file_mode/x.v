module main

fn main() {
	p := unsafe { &int(0) }
	println(p)
}
