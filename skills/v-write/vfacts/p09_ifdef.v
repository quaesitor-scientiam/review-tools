fn main() {
	$if linux {
		x := 'text' + 5
		println(undefined_name(x))
	}
	$if windows {
		println('windows branch ran')
	}
	println('compiled and ran')
}
