module cache

fn test_a_cut_cache_is_removed() {
	$if !windows {
		$if linux {
			assert remove_cut() == true
		} $else {
			assert remove_cut_bsd() == true
		}
	}
}
