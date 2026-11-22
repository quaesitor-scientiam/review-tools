interface Shape {
	area() int
}

struct Sq {
	side int
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
	b := &Conn{
		id: 1
		t:  Sq{
			side: 2
		}
	}
	c := a
	d := &Conn{
		id: 9
		t:  Sq{
			side: 2
		}
	}
	println('two allocations with equal fields: a == b is ${a == b}')
	println('two allocations with one field different: a == d is ${a == d}')
	println('one allocation under two names: a == c is ${a == c}')
	println('addresses of the two allocations: voidptr(a) == voidptr(b) is ${voidptr(a) == voidptr(b)}')
}
