module scan

// V merges a dot only when a name follows it, as V's parser does.
fn merges(next string) bool {
	return next == 'name'
}
