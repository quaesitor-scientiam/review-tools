struct State {
mut:
	n int
}

fn main() {
	mut x := 1
	f := fn [x] () int {
		return x
	}
	x = 2
	println('captured int, read after x = 2: ${f()}')
	mut st := &State{
		n: 1
	}
	g := fn [st] () int {
		return st.n
	}
	st.n = 2
	println('captured &State, read after st.n = 2: ${g()}')
}
