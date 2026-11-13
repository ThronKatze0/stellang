// net: TCP sockets.
// Thin wrappers over the C runtime (src/runtime.c), which calls the POSIX socket API:
// socket/bind/listen, accept, read, write, close.

extern fn st_listen(port: int) -> int
extern fn st_accept(fd: int) -> int
extern fn st_read(fd: int) -> str
extern fn st_write(fd: int, data: str) -> int
extern fn st_close(fd: int)
extern fn st_error() -> str

struct Listener {
    fd: int,
    port: int,
}

struct Conn {
    fd: int,
}

// Listen for TCP connections on every interface.
fn listen(port: int) -> Listener! {
    let fd = st_listen(port)
    if fd < 0 {
        return err("cannot listen on port ${port}: ${st_error()}")
    }
    return Listener { fd, port }
}

impl Listener {
    // Wait for the next client.
    fn accept(self) -> Conn! {
        let fd = st_accept(self.fd)
        if fd < 0 {
            return err("accept failed: " + st_error())
        }
        return Conn { fd }
    }
}

impl Conn {
    // Read one request (headers + body).
    fn read(self) -> str! {
        let data = st_read(self.fd)
        if st_error() != "" {
            return err("read failed: " + st_error())
        }
        return data
    }

    fn write(self, data: str) -> void! {
        if st_write(self.fd, data) < 0 {
            return err("write failed: " + st_error())
        }
    }

    fn close(self) {
        st_close(self.fd)
    }
}
