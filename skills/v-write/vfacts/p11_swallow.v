import os

fn main() {
	os.rm('no_such_dir/no_such_file.txt') or {}
	println('continued after a failed removal')
}
