// fs: files and directories.
//
//     let text = fs.read("notes.txt")?
//     fs.write("out.txt", text.upper())?
//     for name in fs.list(".")? { println(name) }

extern fn st_read_file(path: str) -> str
extern fn st_write_file(path: str, data: str, append: bool) -> int
extern fn st_remove_file(path: str) -> int
extern fn st_mkdir(path: str) -> int
extern fn st_list_dir(path: str) -> [str]
extern fn st_file_size(path: str) -> int
extern fn st_is_dir(path: str) -> bool
extern fn st_error() -> str

// The whole file as a str (text files: a NUL byte ends the str).
fn read(path: str) -> str! {
    let data = st_read_file(path)
    if st_error() != "" {
        return err("cannot read ${path}: ${st_error()}")
    }
    return data
}

// Create or replace the file.
fn write(path: str, data: str) -> void! {
    if st_write_file(path, data, false) < 0 {
        return err("cannot write ${path}: ${st_error()}")
    }
}

fn append(path: str, data: str) -> void! {
    if st_write_file(path, data, true) < 0 {
        return err("cannot write ${path}: ${st_error()}")
    }
}

fn remove(path: str) -> void! {
    if st_remove_file(path) < 0 {
        return err("cannot remove ${path}: ${st_error()}")
    }
}

// Create a directory (fine if it already exists).
fn mkdir(path: str) -> void! {
    if st_mkdir(path) < 0 {
        return err("cannot create ${path}: ${st_error()}")
    }
}

// The names in a directory, sorted.
fn list(path: str) -> [str]! {
    let names = st_list_dir(path)
    if st_error() != "" {
        return err("cannot list ${path}: ${st_error()}")
    }
    return names
}

fn exists(path: str) -> bool {
    return st_file_size(path) >= 0 || st_is_dir(path)
}

fn is_dir(path: str) -> bool {
    return st_is_dir(path)
}

// Size in bytes of a file, or none if it isn't one.
fn size(path: str) -> int? {
    let n = st_file_size(path)
    if n < 0 {
        return none
    }
    return n
}
