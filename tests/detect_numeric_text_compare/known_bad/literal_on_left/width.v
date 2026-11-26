module main

fn is_zero_shift(count string) bool {
	a := '0x00' == count
	b := "0b0" != count.trim_space()
	c := count !in ['+1', '-2']
	d := count in ['x', '0o7']
	e := a / 2 == 1 || count == '7'
	f := count != '3'
	return a || b || c || d || e || f
}
