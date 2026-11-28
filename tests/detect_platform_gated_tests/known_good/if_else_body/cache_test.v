module cache

fn test_a_cut_cache_is_removed_on_every_host() {
	$if !windows {
		assert remove_cut() == true
	} $else {
		assert remove_cut_windows() == true
	}
}
