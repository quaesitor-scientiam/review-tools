import os

fn main() {
	st := os.lstat(os.executable()) or { panic(err) }
	uid_is_zero := os.getuid() == 0
	inode_is_zero := st.inode == 0
	println('getuid is 0: ${uid_is_zero} lstat inode of this program is 0: ${inode_is_zero}')
}
