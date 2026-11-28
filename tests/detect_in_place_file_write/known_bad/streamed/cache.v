module m

import os

fn save(path string, lines []string) {
	mut f := os.create(path) or { return }
	for l in lines {
		f.write_string(l) or { break }
	}
	f.close()
}
