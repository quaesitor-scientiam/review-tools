module m

import os

fn save(path string, text string) ! {
	os.write_file(path, text)!
}
