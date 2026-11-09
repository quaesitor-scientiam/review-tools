module scan

// merges reports whether the next token continues the current name.
fn merges(next string) bool {
	return next == 'name'
}
