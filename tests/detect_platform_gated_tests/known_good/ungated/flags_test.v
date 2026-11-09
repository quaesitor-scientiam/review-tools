module flags

fn test_flags_are_recorded() {
	$if debug {
		println('checking flags')
	}
	assert flags() == 2
}
