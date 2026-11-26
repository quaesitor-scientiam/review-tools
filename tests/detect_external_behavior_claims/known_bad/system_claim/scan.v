module scan

// The system answers EACCES or EAGAIN when another process holds the lock.
fn held(code int) bool {
	return code == 13 || code == 11
}