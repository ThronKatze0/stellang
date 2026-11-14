// The file system: directories and text files, addressed by paths like "/home/notes.txt". It lives
// in RAM; with a disk it's saved there (`save`, a few seconds after each change) and loaded at boot.
//
// Every file and directory has an owner and a mode, like Unix: read/write/enter bits for the owner
// (0o700) and for everyone else (0o007); group bits are kept but play no part. `who` is whoever is
// acting now (the logged-in user; "root" may do anything): read, write, list, mkdir and remove check
// that they may. A path is only reachable if every directory on the way may be entered, so a
// private home (0o700) keeps everything in it private.

import kernel
import disk

const MAGIC = "STELLAFS 1"
const MAGIC2 = "STELLAFS 2"

const FILE_MODE = 420         // 0o644: the owner writes, everyone reads
const DIR_MODE = 493          // 0o755
const PRIVATE = 448           // 0o700: the owner only

struct RamFs {
    files: {str: str} = {},
    dirs: {str} = {"/"},
    changes: int = 0,         // bumped by every change, so the saver knows
    owners: {str: str} = {},
    modes: {str: int} = {},
    who: str = "root",

    fn owner(self, path: str) -> str { return self.owners.get(path) ?? "root" }
    fn mode(self, path: str) -> int { return self.modes.get(path) ?? (if self.is_dir(path) { DIR_MODE } else { FILE_MODE }) }

    // may `user` do `what` (4 read, 2 write, 1 enter) to `path` (which exists)?
    fn may(self, user: str, path: str, what: int) -> bool {
        if user == "root" { return true }
        let m = self.mode(path)
        let bits = if self.owner(path) == user { m >> 6 } else { m }
        return bits & what == what
    }

    // can `user` get to `path`: may they enter every directory above it?
    fn reachable(self, user: str, path: str) -> bool {
        if user == "root" { return true }
        var p = self.parent(path)
        while true {
            if self.is_dir(p) && !self.may(user, p, 1) { return false }
            if p == "/" { return true }
            p = self.parent(p)
        }
        return true
    }

    fn can_read(self, user: str, path: str) -> bool { return self.reachable(user, path) && self.may(user, path, 4) }
    fn can_write(self, user: str, path: str) -> bool {
        if !self.reachable(user, path) { return false }
        if self.exists(path) { return self.may(user, path, 2) }
        let dir = self.parent(path)
        return self.is_dir(dir) && self.may(user, dir, 2 | 1)
    }

    fn denied(self, path: str) -> str { return "permission denied: ${path}" }

    fn chmod(self, path: str, mode: int) -> void! {
        if !self.exists(path) { return err("no such file or directory: ${path}") }
        if self.who != "root" && self.owner(path) != self.who { return err("only ${self.owner(path)} (or root) can change ${path}") }
        self.modes[path] = mode & 511
        self.changes += 1
    }

    fn chown(self, path: str, user: str) -> void! {
        if !self.exists(path) { return err("no such file or directory: ${path}") }
        if self.who != "root" { return err("only root can give files away") }
        self.owners[path] = user
        self.changes += 1
    }

    // a file or directory made by `user` (the system's own work: as root)
    fn make_as(self, user: str, path: str, mode: int) {
        self.owners[path] = user
        self.modes[path] = mode
    }

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

    fn read(self, path: str) -> str! { return self.read_as(self.who, path) }

    fn read_as(self, user: str, path: str) -> str! {
        if self.is_dir(path) { return err("${path} is a directory") }
        if let t = self.files.get(path) {
            if !self.can_read(user, path) { return err(self.denied(path)) }
            return t
        }
        return err("no such file: ${path}")
    }

    fn write(self, path: str, text: str) -> void! { self.write_as(self.who, path, text)? }

    fn write_as(self, user: str, path: str, text: str) -> void! {
        if self.is_dir(path) { return err("${path} is a directory") }
        if !self.is_dir(self.parent(path)) { return err("no such directory: ${self.parent(path)}") }
        if !self.can_write(user, path) { return err(self.denied(path)) }
        if !self.is_file(path) { self.make_as(user, path, FILE_MODE) }
        self.files[path] = text
        self.changes += 1
    }

    fn mkdir(self, path: str) -> void! {
        if self.exists(path) { return err("${path} already exists") }
        if !self.is_dir(self.parent(path)) { return err("no such directory: ${self.parent(path)}") }
        if !self.can_write(self.who, path) { return err(self.denied(path)) }
        self.dirs.add(path)
        self.make_as(self.who, path, DIR_MODE)
        self.changes += 1
    }

    fn remove(self, path: str) -> void! {
        if path == "/" { return err("can't remove /") }
        if !self.exists(path) { return err("no such file or directory: ${path}") }
        let dir = self.parent(path)
        if self.who != "root" && !(self.reachable(self.who, path) && self.may(self.who, dir, 2 | 1)) { return err(self.denied(path)) }
        if self.is_file(path) {
            self.files.remove(path)
            self.forget(path)
            self.changes += 1
            return
        }
        if !self.list(path).is_empty() { return err("${path} isn't empty") }
        self.dirs.remove(path)
        self.forget(path)
        self.changes += 1
    }

    fn forget(self, path: str) {
        if self.owners.contains(path) { self.owners.remove(path) }
        if self.modes.contains(path) { self.modes.remove(path) }
    }

    // `rwxr-xr-x`-style
    fn mode_text(self, path: str) -> str {
        let m = self.mode(path)
        var s = if self.is_dir(path) { "d" } else { "-" }
        for shift in [6, 3, 0] {
            let b = m >> shift
            s += if b & 4 != 0 { "r" } else { "-" }
            s += if b & 2 != 0 { "w" } else { "-" }
            s += if b & 1 != 0 { "x" } else { "-" }
        }
        return s
    }

    // the names in a directory, directories first (with a trailing /)
    fn list(self, dir: str) -> [str] {
        var subdirs: [str] = []
        if !self.can_read(self.who, dir) { return subdirs }
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
            if p != "/" { parts.push("D ${self.owner(p)} ${self.mode(p)} ${p}\n") }
        }
        for p in self.files.keys() {
            let t = self.files[p]
            parts.push("F ${self.owner(p)} ${self.mode(p)} ${p} ${t.len()}\n${t}")
        }
        let body = parts.join("")
        let sectors = (body.len() + disk.SECTOR - 1) / disk.SECTOR
        if (sectors + 1) * disk.SECTOR > d.size() { return err("the disk is full (${d.size()} bytes)") }
        let buf = kernel.alloc((sectors + 1) * disk.SECTOR)
        kernel.write_str(buf, "${MAGIC2} ${body.len()}\n")
        kernel.write_str(buf + disk.SECTOR, body)
        d.write(0, sectors + 1, buf)?
    }

    // Load what's on the disk. Returns false if it holds no file system yet.
    fn load(self, d: disk.Disk) -> bool! {
        let buf = kernel.alloc(disk.SECTOR)
        d.read(0, 1, buf)?
        let head = kernel.read_str(buf, 64)
        let v2 = head.starts_with(MAGIC2 + " ")
        if !head.starts_with(MAGIC + " ") && !v2 { return false }
        let size = int(head.slice(MAGIC.len() + 1, head.find("\n")))?
        let sectors = (size + disk.SECTOR - 1) / disk.SECTOR
        let data = kernel.alloc(max(sectors, 1) * disk.SECTOR)
        if sectors > 0 { d.read(1, sectors, data)? }
        let body = kernel.read_str(data, size)
        self.files = {}
        self.dirs = {"/"}
        self.owners = {}
        self.modes = {}
        var at = 0
        while at < body.len() {
            let rest = body.slice(at, body.len())
            let nl = rest.find("\n")
            if nl < 0 { break }
            let line = rest.slice(0, nl)
            at += nl + 1
            var rest2 = line.slice(2, line.len())
            var owner = "root"
            var mode = -1
            if v2 && (line.starts_with("D ") || line.starts_with("F ")) {
                let a = rest2.find(" ")
                owner = rest2.slice(0, a)
                rest2 = rest2.slice(a + 1, rest2.len())
                let b = rest2.find(" ")
                mode = int(rest2.slice(0, b))?
                rest2 = rest2.slice(b + 1, rest2.len())
            }
            if line.starts_with("D ") {
                self.dirs.add(rest2)
                if v2 { self.make_as(owner, rest2, mode) }
            } else if line.starts_with("F ") {
                let sp = rest2
                let cut = last_space(sp)
                let n = int(sp.slice(cut + 1, sp.len()))?
                let path = sp.slice(0, cut)
                self.files[path] = body.slice(at, at + n)
                if v2 { self.make_as(owner, path, mode) }
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
