#include <time.h>

struct C.tm {
	tm_sec int
}

interface Shape {
	area() int
}

struct Sq {
	side int
	raw  C.tm
}

fn (s Sq) area() int {
	return s.side
}

struct Conn {
	id int
	t  Shape
}

fn main() {
	a := &Conn{
		id: 1
		t:  Sq{
			side: 2
		}
	}
	b := a
	println('pointer == where the interface value holds a C struct: ${a == b}')
}
