// A filesystem in RAM: directories and text files, addressed by paths like "/home/notes.txt".

struct RamFs {
    files: {str: str} = {},
    dirs: {str} = {"/"},

    // `path` made absolute against `cwd`, with "." and ".." resolved
    fn resolve(self, cwd: str, path: str) -> str {
        let full = if path.starts_with("/") { path } else { "${cwd}/${path}" }
        var parts: [str] = []
        for p in full.split("/") {
            if p == "" || p == "." { continue }
            if p == ".." {
                if !parts.is_empty() { parts.pop() }
                continue
            }
            parts.push(p)
        }
        return "/" + parts.join("/")
    }

    fn parent(self, path: str) -> str {
        let parts = path.split("/").filter(p => p != "")
        if parts.len() <= 1 { return "/" }
        return "/" + parts.slice(0, parts.len() - 1).join("/")
    }

    fn name(self, path: str) -> str {
        return path.split("/").last() ?? ""
    }

    fn is_dir(self, path: str) -> bool { return path in self.dirs }
    fn is_file(self, path: str) -> bool { return path in self.files }
    fn exists(self, path: str) -> bool { return self.is_dir(path) || self.is_file(path) }

    fn read(self, path: str) -> str! {
        if self.is_dir(path) { return err("${path} is a directory") }
        if let t = self.files.get(path) { return t }
        return err("no such file: ${path}")
    }

    fn write(self, path: str, text: str) -> void! {
        if self.is_dir(path) { return err("${path} is a directory") }
        if !self.is_dir(self.parent(path)) { return err("no such directory: ${self.parent(path)}") }
        self.files[path] = text
    }

    fn mkdir(self, path: str) -> void! {
        if self.exists(path) { return err("${path} already exists") }
        if !self.is_dir(self.parent(path)) { return err("no such directory: ${self.parent(path)}") }
        self.dirs.add(path)
    }

    fn remove(self, path: str) -> void! {
        if path == "/" { return err("can't remove /") }
        if self.is_file(path) {
            self.files.remove(path)
            return
        }
        if !self.is_dir(path) { return err("no such file or directory: ${path}") }
        if !self.list(path).is_empty() { return err("${path} isn't empty") }
        self.dirs.remove(path)
    }

    // the names in a directory, directories first (with a trailing /)
    fn list(self, dir: str) -> [str] {
        var subdirs: [str] = []
        var names: [str] = []
        for d in self.dirs {
            if d != "/" && self.parent(d) == dir { subdirs.push(self.name(d) + "/") }
        }
        for f in self.files.keys() {
            if self.parent(f) == dir { names.push(self.name(f)) }
        }
        subdirs.sort()
        names.sort()
        for n in names { subdirs.push(n) }
        return subdirs
    }

    // total bytes in files
    fn used(self) -> int {
        return self.files.values().map(t => t.len()).sum()
    }
}
