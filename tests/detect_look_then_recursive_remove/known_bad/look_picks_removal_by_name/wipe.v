module main

import os

struct Dir {
	path string
}

fn open_dir(path string) !Dir {
	return Dir{path}
}

fn (d Dir) remove_tree(name string) ! {}

// wipe opens the folder to act through its handle, but a link seen at the path is removed whole
// by name, even if a build has put a real folder there since the look.
fn wipe(path string) ! {
	dir := open_dir(path)!
	if os.is_link(path) {
		os.rmdir_all(path)!
		return
	}
	dir.remove_tree('entry')!
}
