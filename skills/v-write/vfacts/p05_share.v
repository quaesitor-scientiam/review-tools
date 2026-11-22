struct Box {
mut:
	items []int
}

fn (b &Box) get() []int {
	return b.items
}

fn (b &Box) get_copy() []int {
	return b.items.clone()
}

fn main() {
	mut b := Box{
		items: [1, 2, 3]
	}
	mut g := b.get()
	g[0] = 99
	println('box after a write through get(): ${b.items}')
	mut c := b.get_copy()
	c[1] = 77
	println('box after a write through get_copy(): ${b.items}')
	mut a := [1, 2, 3, 4]
	mut s := a[..2]
	s[0] = 50
	println('parent after a write through its slice: ${a}')
	s << 60
	s[1] = 70
	println('parent after the slice grew and was written again: ${a} slice=${s}')
}
