// The file system: directories and text files, addressed by paths like "/home/notes.txt". It lives
// in RAM; with a disk it's saved there (`save`, a few seconds after each change) and loaded at boot.

import kernel
import disk

const MAGIC = "STELLAFS 1"

struct RamFs {
    files: {str: str} = {},
    dirs: {str} = {"/"},
    changes: int = 0,         // bumped by every change, so the saver knows

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
        self.changes += 1
    }

    fn mkdir(self, path: str) -> void! {
        if self.exists(path) { return err("${path} already exists") }
        if !self.is_dir(self.parent(path)) { return err("no such directory: ${self.parent(path)}") }
        self.dirs.add(path)
        self.changes += 1
    }

    fn remove(self, path: str) -> void! {
        if path == "/" { return err("can't remove /") }
        if self.is_file(path) {
            self.files.remove(path)
            self.changes += 1
            return
        }
        if !self.is_dir(path) { return err("no such file or directory: ${path}") }
        if !self.list(path).is_empty() { return err("${path} isn't empty") }
        self.dirs.remove(path)
        self.changes += 1
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

    // ---- on disk ----
    //
    // Sector 0: "STELLAFS 1 <bytes>\n". From sector 1: the directories ("D <path>\n") and files
    // ("F <path> <bytes>\n" and the text), in one piece.

    fn save(self, d: disk.Disk) -> void! {
        var parts: [str] = []
        var dirs: [str] = []
        for p in self.dirs { dirs.push(p) }
        dirs.sort()
        for p in dirs {
            if p != "/" { parts.push("D ${p}\n") }
        }
        for p in self.files.keys() {
            let t = self.files[p]
            parts.push("F ${p} ${t.len()}\n${t}")
        }
        let body = parts.join("")
        let sectors = (body.len() + disk.SECTOR - 1) / disk.SECTOR
        if (sectors + 1) * disk.SECTOR > d.size() { return err("the disk is full (${d.size()} bytes)") }
        let buf = kernel.alloc((sectors + 1) * disk.SECTOR)
        kernel.write_str(buf, "${MAGIC} ${body.len()}\n")
        kernel.write_str(buf + disk.SECTOR, body)
        d.write(0, sectors + 1, buf)?
    }

    // Load what's on the disk. Returns false if it holds no file system yet.
    fn load(self, d: disk.Disk) -> bool! {
        let buf = kernel.alloc(disk.SECTOR)
        d.read(0, 1, buf)?
        let head = kernel.read_str(buf, 64)
        if !head.starts_with(MAGIC + " ") { return false }
        let size = int(head.slice(MAGIC.len() + 1, head.find("\n")))?
        let sectors = (size + disk.SECTOR - 1) / disk.SECTOR
        let data = kernel.alloc(max(sectors, 1) * disk.SECTOR)
        if sectors > 0 { d.read(1, sectors, data)? }
        let body = kernel.read_str(data, size)
        self.files = {}
        self.dirs = {"/"}
        var at = 0
        while at < body.len() {
            let rest = body.slice(at, body.len())
            let nl = rest.find("\n")
            if nl < 0 { break }
            let line = rest.slice(0, nl)
            at += nl + 1
            if line.starts_with("D ") {
                self.dirs.add(line.slice(2, line.len()))
            } else if line.starts_with("F ") {
                let sp = line.slice(2, line.len())
                let cut = last_space(sp)
                let n = int(sp.slice(cut + 1, sp.len()))?
                self.files[sp.slice(0, cut)] = body.slice(at, at + n)
                at += n
            } else {
                return err("the file system on the disk is damaged")
            }
        }
        return true
    }
}

fn last_space(s: str) -> int {
    var i = s.len() - 1
    while i >= 0 && s.slice(i, i + 1) != " " { i -= 1 }
    return i
}
