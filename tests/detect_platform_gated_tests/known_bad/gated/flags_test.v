module flags

fn test_flags_build_as_v_does() {
	$if !macos && !linux {
		return
	}
	assert flags() == 2
}
