module cache

fn test_a_cut_cache_is_removed() {
	$if !windows {
		limit := $if linux { 2048 } $else { 4096 }
		assert remove_cut(limit) == true
	}
}
