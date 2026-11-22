fn test_gated() {
	$if !some_flag ? {
		return
	}
	assert 1 == 2
}
