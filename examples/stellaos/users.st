// users: accounts, passwords and logging in.
//
//   /etc/passwd   name:uid:home:admin   (everyone may read it)
//   /etc/shadow   name:rounds:salt:hash (root only): PBKDF2-HMAC-SHA256 of the password with a
//                 random salt and 10000 rounds, so a stolen shadow file is slow to guess from and
//                 two people with the same password don't get the same hash
//
// Each user has a home, /home/<name>, that only they (and root) can get into. Admins may run
// commands as root with `sudo` (after typing their own password again). Failed logins slow down:
// every wrong password makes the next attempt wait longer.

import kernel
import ramfs
import sha2

const ROUNDS = 10000

struct Account {
    name: str,
    uid: int,
    home: str,
    admin: bool,
}

struct Users {
    fs: ramfs.RamFs,
    random: fn() -> int,
    failures: int = 0,
    locked_until: int = 0,

    fn accounts(self) -> [Account] {
        var out: [Account] = []
        let text = self.fs.files.get("/etc/passwd") ?? ""
        for l in text.lines() {
            let f = l.split(":")
            if f.len() < 4 { continue }
            out.push(Account { name: f[0], uid: int(f[1]) catch 0, home: f[2], admin: f[3] == "admin" })
        }
        return out
    }

    // people (not root)
    fn people(self) -> [Account] { return self.accounts().filter(a => a.name != "root") }

    fn find(self, name: str) -> Account? { return self.accounts().find(a => a.name == name) }

    fn valid_name(self, name: str) -> str {
        if name.len() < 1 || name.len() > 16 { return "a user name is 1 to 16 characters" }
        for k, c in name.chars() {
            let ok_char = (c >= "a" && c <= "z") || (k > 0 && ((c >= "0" && c <= "9") || c == "-" || c == "_"))
            if !ok_char { return "a user name is lowercase letters (and digits, - or _ after the first)" }
        }
        if name == "root" || name == "examples" { return "${name} is taken" }
        return ""
    }

    // a new account (and its private home)
    fn create(self, name: str, password: str, admin: bool) -> void! {
        let problem = self.valid_name(name)
        if problem != "" { return err(problem) }
        if self.find(name) != none { return err("there already is a user called ${name}") }
        if password.len() < 4 { return err("a password needs at least 4 characters") }
        let uid = 1000 + self.people().len()
        let home = "/home/${name}"
        let fs = self.fs
        let was = fs.who
        fs.who = "root"
        let passwd = fs.files.get("/etc/passwd") ?? "root:0:/root:admin\n"
        fs.write("/etc/passwd", passwd + "${name}:${uid}:${home}:${if admin { "admin" } else { "user" }}\n")?
        fs.chmod("/etc/passwd", ramfs.FILE_MODE)?
        let shadow = fs.files.get("/etc/shadow") ?? ""
        fs.write("/etc/shadow", shadow + self.entry(name, password))?
        fs.chmod("/etc/shadow", 384)?                       // 0o600: root only
        if !fs.is_dir(home) { fs.mkdir(home)? }
        fs.chown(home, name)?
        fs.chmod(home, ramfs.PRIVATE)?
        fs.who = was
    }

    fn entry(self, name: str, password: str) -> str {
        var salt: [int] = []
        for k in 0..16 { salt.push(self.random() & 255) }
        return "${name}:${ROUNDS}:${sha2.hex(salt)}:${sha2.hex(pbkdf2(password, salt, ROUNDS))}\n"
    }

    // Is this the user's password? Wrong answers make the next try wait (1 s, 2 s, 4 s, ... 30 s).
    fn check(self, name: str, password: str) -> str {
        let now = kernel.uptime()
        if now < self.locked_until { return "too many wrong passwords: wait ${(self.locked_until - now + 999) / 1000} s" }
        let text = self.fs.files.get("/etc/shadow") ?? ""
        for l in text.lines() {
            let f = l.split(":")
            if f.len() != 4 || f[0] != name { continue }
            let rounds = int(f[1]) catch ROUNDS
            let want = sha2.unhex(f[3])
            let got = pbkdf2(password, sha2.unhex(f[2]), rounds)
            if same(want, got) {
                self.failures = 0
                return ""
            }
        }
        // an unknown user gets the same answer (and takes as long) as a wrong password
        if self.find(name) == none { pbkdf2(password, [0], ROUNDS) }
        self.failures += 1
        self.locked_until = kernel.uptime() + min(30000, 500 << min(self.failures, 6))
        return "wrong user name or password"
    }

    fn set_password(self, name: str, password: str) -> void! {
        if password.len() < 4 { return err("a password needs at least 4 characters") }
        let text = self.fs.files.get("/etc/shadow") ?? ""
        var out: [str] = []
        var found = false
        for l in text.lines() {
            if l.split(":")[0] == name {
                out.push(self.entry(name, password).trim())
                found = true
            } else if l != "" {
                out.push(l)
            }
        }
        if !found { return err("no user called ${name}") }
        let was = self.fs.who
        self.fs.who = "root"
        self.fs.write("/etc/shadow", out.join("\n") + "\n")?
        self.fs.who = was
    }
}

// PBKDF2-HMAC-SHA256, one 32-byte block
fn pbkdf2(password: str, salt: [int], rounds: int) -> [int] {
    let key = sha2.bytes_of(password)
    var first = salt.slice(0, salt.len())
    for b in [0, 0, 0, 1] { first.push(b) }
    var u = sha2.hmac256(key, first)
    var t = u.slice(0, u.len())
    for r in 1..rounds {
        u = sha2.hmac256(key, u)
        for k in 0..32 { t[k] = t[k] ^ u[k] }
    }
    return t
}

// compare without stopping at the first difference (no timing hints)
fn same(a: [int], b: [int]) -> bool {
    if a.len() != b.len() { return false }
    var d = 0
    for k in 0..a.len() { d = d | (a[k] ^ b[k]) }
    return d == 0
}
