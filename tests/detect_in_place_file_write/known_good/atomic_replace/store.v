module m

import os

fn save(path string, lines []string) ! {
	tmp := path + '.new'
	mut f := os.create(tmp)!
	for l in lines {
		f.write_string(l)!
	}
	f.close()
	atomic_replace(tmp, path)!
}
