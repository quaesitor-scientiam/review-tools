module cache

fn test_a_cut_cache_is_removed() {
	$if !windows {
		assert remove_cut() == true
	}

}
