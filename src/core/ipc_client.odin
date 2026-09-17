package core

// Shared Unix-socket client transport for skarwm IPC consumers. Protocol
// framing remains in ipc.odin; this file keeps socket discovery, connection,
// and complete-frame I/O identical for skarwm-msg and the bar.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import cc "core:c"

Ipc_Default_Socket_Path :: proc() -> string {
    buffer: [512]u8
    if path := os.get_env_buf(buffer[:], "SKARWM_SOCKET"); path != "" {
        return strings.clone(path)
    }
    if directory := os.get_env_buf(buffer[:], "XDG_RUNTIME_DIR"); directory != "" {
        return strings.concatenate({directory, "/skarwm.sock"})
    }
    return fmt.aprintf("/tmp/skarwm-%d.sock", posix.geteuid())
}

Ipc_Connect :: proc(path: string) -> posix.FD {
    if len(path) >= len(posix.sockaddr_un{}.sun_path) { return -1 }
    fd := posix.socket(.UNIX, .STREAM)
    if fd < 0 { return -1 }
    address: posix.sockaddr_un
    address.sun_family = .UNIX
    for character, index in path { address.sun_path[index] = cc.char(character) }
    if posix.connect(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address))) == .FAIL {
        posix.close(fd)
        return -1
    }
    return fd
}

Ipc_Send_All :: proc(fd: posix.FD, data: []byte) -> bool {
    offset := 0
    for offset < len(data) {
        count := posix.send(fd, raw_data(data[offset:]), cc.size_t(len(data[offset:])), {.NOSIGNAL})
        if count > 0 { offset += int(count); continue }
        if count < 0 && posix.errno() == .EINTR { continue }
        return false
    }
    return true
}

ipc_recv_exact :: proc(fd: posix.FD, data: []byte) -> bool {
    offset := 0
    for offset < len(data) {
        count := posix.recv(fd, raw_data(data[offset:]), cc.size_t(len(data[offset:])), {})
        if count > 0 { offset += int(count); continue }
        if count < 0 && posix.errno() == .EINTR { continue }
        return false
    }
    return true
}

Ipc_Recv_Frame :: proc(fd: posix.FD) -> (Ipc_Frame, bool) {
    header: [IPC_HEADER_BYTES]u8
    if !ipc_recv_exact(fd, header[:]) { return {}, false }
    if string(header[:len(IPC_MAGIC)]) != IPC_MAGIC { return {}, false }
    count := int(le_u32(header[6:10]))
    if count > IPC_MAX_PAYLOAD { return {}, false }
    payload := make([]byte, count)
    if count > 0 && !ipc_recv_exact(fd, payload) {
        delete(payload)
        return {}, false
    }
    return Ipc_Frame{typ = le_u32(header[10:14]), payload = payload}, true
}
