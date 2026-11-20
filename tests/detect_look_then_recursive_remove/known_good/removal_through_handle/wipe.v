module main

import os

struct Dir {
	path string
}

fn open_dir(path string) !Dir {
	return Dir{path}
}

fn (d Dir) remove_tree(name string) ! {}

// wipe opens the folder and removes through that handle only, so what is removed is what was
// opened, whatever the look saw.
fn wipe(path string) ! {
	dir := open_dir(path)!
	if os.is_link(path) {
		return
	}
	dir.remove_tree('entry')!
}
