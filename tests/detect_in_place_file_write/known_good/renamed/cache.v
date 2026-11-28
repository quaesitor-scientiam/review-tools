module m

import os

fn save(path string, lines []string) {
	tmp := '${path}.tmp'
	mut f := os.create(tmp) or { return }
	for l in lines {
		f.write_string(l) or { break }
	}
	f.close()
	os.rename(tmp, path) or {}
}
