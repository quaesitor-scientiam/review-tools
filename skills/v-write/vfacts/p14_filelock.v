import os
import os.filelock

fn make_lock(kind string, path string) filelock.FileLock {
	if kind == 'new_file' {
		return filelock.new_file(path)
	}
	return filelock.new(path)
}

// child runs in a second process: it reports whether it could take the lock.
fn child(kind string, path string) {
	mut l := make_lock(kind, path)
	if l.try_acquire() {
		println('acquired')
		l.release()
	} else {
		println('refused')
	}
}

fn ask_child(kind string, path string) string {
	res := os.exec([os.executable(), 'child', kind, path])
	return res.output.trim_space()
}

fn main() {
	if os.args.len == 4 && os.args[1] == 'child' {
		child(os.args[2], os.args[3])
		return
	}
	dir := os.join_path(os.temp_dir(), 'vfacts_filelock_${os.getpid()}')
	os.mkdir_all(dir)!
	for kind in ['new_file', 'new'] {
		path := os.join_path(dir, '${kind}.lock')
		os.write_file(path, 'x')!
		mut l := make_lock(kind, path)
		l.acquire()!
		held := ask_child(kind, path)
		mut reopened := 'opened and closed'
		if mut f := os.open(path) {
			f.close()
		} else {
			reopened = 'could not open'
		}
		after := ask_child(kind, path)
		println('filelock.${kind}: second process while held: ${held}; this process ${reopened} the file again; second process then: ${after}')
		l.release()
	}
	// A leftover temp folder is harmless, so a failed removal is not reported.
	os.rmdir_all(dir) or {}
}
