///|
#external
pub type Handle

///|
#borrow(path)
extern "C" fn open_raw(path : Bytes, write : Int32) -> Handle = "rl_open"

///|
extern "C" fn is_null(handle : Handle) -> Int32 = "rl_null"

///|
extern "C" fn close_raw(handle : Handle) -> Int32 = "rl_close"

///|
extern "C" fn sync_raw(handle : Handle) -> Int32 = "rl_sync"

///|
extern "C" fn line_raw(handle : Handle, limit : Int32) -> Bytes = "rl_line"

///|
extern "C" fn status_raw(handle : Handle) -> Int32 = "rl_status"

///|
extern "C" fn tell_raw(handle : Handle) -> Int64 = "rl_tell"

///|
extern "C" fn seek_raw(handle : Handle, offset : Int64) -> Int32 = "rl_seek"

///|
#borrow(data)
extern "C" fn write_raw(handle : Handle, data : Bytes) -> Int32 = "rl_write"

///|
#borrow(path)
extern "C" fn mkdir_raw(path : Bytes) -> Int32 = "rl_mkdir"

///|
#borrow(path)
extern "C" fn private_raw(path : Bytes) -> Int32 = "rl_private_dir"

///|
#borrow(path)
extern "C" fn lock_raw(path : Bytes) -> Handle = "rl_lock"

///|
#borrow(source, destination, directory)
extern "C" fn rename_raw(
  source : Bytes,
  destination : Bytes,
  directory : Bytes,
) -> Int32 = "rl_rename"

///|
#borrow(path)
extern "C" fn size_raw(path : Bytes) -> Int64 = "rl_size"

///|
#borrow(data)
extern "C" fn hash_raw(data : Bytes) -> Bytes = "rl_hash_bytes"

///|
#borrow(path)
extern "C" fn hash_file_raw(path : Bytes) -> Bytes = "rl_hash_file"

///|
pub(all) suberror IOError {
  IOError(String)
}

///|
pub struct File {
  handle : Handle
  mut closed : Bool
}

///|
pub(all) enum Line {
  End
  Text(String)
  TooLong
  InvalidUtf8
}

///|
fn os_path(path : String) -> Bytes raise IOError {
  if path.contains("\u0000") {
    raise IOError("NUL in filesystem path")
  }
  @utf8.encode(path) + b"\x00"
}

///|
pub fn open(path : String, write~ : Bool = false) -> File raise IOError {
  let handle = open_raw(os_path(path), if write { 1 } else { 0 })
  if is_null(handle) != 0 {
    raise IOError(
      "cannot open regular workspace/source file; symlinks are not followed",
    )
  }
  { handle, closed: false, }
}

///|
pub fn File::close(self : File) -> Unit {
  if !self.closed {
    self.closed = true
    ignore(close_raw(self.handle))
  }
}

///|
pub fn File::sync(self : File) -> Unit raise IOError {
  if self.closed || sync_raw(self.handle) != 0 {
    raise IOError("cannot flush and sync file")
  }
}

///|
pub fn File::position(self : File) -> Int64 raise IOError {
  if self.closed {
    raise IOError("cannot query a closed stream")
  }
  let position = tell_raw(self.handle)
  if position < 0L {
    raise IOError("cannot query file offset")
  }
  position
}

///|
pub fn File::seek(self : File, offset : Int64) -> Unit raise IOError {
  if self.closed || offset < 0L || seek_raw(self.handle, offset) != 0 {
    raise IOError("cannot seek file")
  }
}

///|
pub fn File::read_line(self : File, limit : Int32) -> Line raise IOError {
  if self.closed || limit < 1 || limit > 16 * 1024 * 1024 {
    raise IOError("invalid line reader state or bound")
  }
  let bytes = line_raw(self.handle, limit)
  match status_raw(self.handle) {
    0 => End
    1 => {
      let text = @utf8.decode(bytes[:], ignore_bom=false) catch {
        _ => return InvalidUtf8
      }
      Text(text)
    }
    2 => TooLong
    _ => raise IOError("error reading input stream")
  }
}

///|
pub fn File::write(self : File, text : String) -> Unit raise IOError {
  if self.closed || write_raw(self.handle, @utf8.encode(text)) != 0 {
    raise IOError("error writing output stream")
  }
}

///|
pub fn File::write_line(self : File, text : String) -> Unit raise IOError {
  self.write(text + "\n")
}

///|
pub fn create_workspace(path : String) -> Unit raise IOError {
  if mkdir_raw(os_path(path)) != 0 {
    raise IOError(
      "workspace must be a new directory; use resume for an existing job",
    )
  }
}

///|
pub fn lock_workspace(path : String) -> File raise IOError {
  if private_raw(os_path(path)) == 0 {
    raise IOError(
      "workspace must be a private, owned POSIX directory (mode 0700)",
    )
  }
  let handle = lock_raw(os_path(path + "/.lock"))
  if is_null(handle) != 0 {
    raise IOError("workspace is locked by another process or cannot be locked")
  }
  { handle, closed: false, }
}

///|
pub fn atomic_rename(
  source : String,
  destination : String,
  directory : String,
) -> Unit raise IOError {
  if rename_raw(os_path(source), os_path(destination), os_path(directory)) != 0 {
    raise IOError("atomic rename or directory sync failed")
  }
}

///|
pub fn file_size(path : String) -> Int64 raise IOError {
  let size = size_raw(os_path(path))
  if size < 0L {
    raise IOError("cannot stat regular file; symlinks are not followed")
  }
  size
}

///|
pub fn sha256(text : String) -> String {
  @utf8.decode_lossy(hash_raw(@utf8.encode(text)))
}

///|
pub fn file_sha256(path : String) -> String raise IOError {
  let digest = hash_file_raw(os_path(path))
  if digest.length() != 64 {
    raise IOError("cannot fingerprint file")
  }
  @utf8.decode_lossy(digest)
}

///|
pub fn write_atomic(
  path : String,
  text : String,
  directory : String,
) -> Unit raise IOError {
  let writer = open(path + ".tmp", write=true)
  defer writer.close()
  writer.write(text)
  writer.sync()
  writer.close()
  atomic_rename(path + ".tmp", path, directory)
}
