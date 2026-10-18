module http

fn parse_status(s string) !int {
	if s.len != 3 || !s.all_digits() {
		return error('bad status')
	}
	return s.int()
}
