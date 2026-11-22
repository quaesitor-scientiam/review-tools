fn main() {
	x := 2147483647
	y := x + 1
	println('sizeof(int)=${sizeof(int)} typeof(y)=${typeof(y).name} 2147483647+1=${y}')
	z := i32(x) + i32(1)
	println('same sum in i32: ${z}')
	n := 256
	println('u8(256)=${u8(n)} u8(300)=${u8(n + 44)}')
	neg := -2
	u := u32(4294967294)
	println('u32(-2) == u32(4294967294): ${u32(neg) == u}')
	println('i64(-2) == i64(u): ${i64(neg) == i64(u)}')
}
