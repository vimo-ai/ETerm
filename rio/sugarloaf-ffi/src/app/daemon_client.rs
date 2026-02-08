//! Thin daemon client embedded in sugarloaf-ffi.
//! Speaks the pty-daemon protocol (4-byte BE length + JSON) with SCM_RIGHTS fd passing.
//! Does NOT depend on pty-daemon crate - duplicates minimal protocol types.

use serde::{Deserialize, Serialize};
use std::env;
use std::io::{Read, Write};
use std::os::unix::io::RawFd;
use std::os::unix::net::UnixStream;

const DEFAULT_SOCKET_PATH: &str = "/tmp/eterm-daemon.sock";

// Protocol types

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Request {
    Create {
        shell: Option<String>,
        cols: u16,
        rows: u16,
        working_dir: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_id: Option<u32>,
    },
    Attach {
        session_id: String,
    },
    Detach {
        session_id: String,
        cols: u16,
        rows: u16,
    },
    List,
    Kill {
        session_id: String,
    },
    WinsizeUpdate {
        session_id: String,
        cols: u16,
        rows: u16,
    },
    Ping,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Response {
    Created {
        session_id: String,
    },
    AttachReady {
        session_id: String,
        cols: u16,
        rows: u16,
        child_pid: i32,
        /// 共享内存名称，客户端从 shm 直接读取历史数据
        shm_name: String,
    },
    AttachDeny {
        session_id: String,
        reason: String,
    },
    Detached {
        session_id: String,
    },
    SessionList {
        sessions: Vec<SessionInfo>,
    },
    Killed {
        session_id: String,
    },
    WinsizeUpdated {
        session_id: String,
    },
    Pong {
        version: u16,
        session_count: usize,
    },
    Error {
        message: String,
    },
}

/// 与 daemon 协议匹配的 SessionInfo（字段名必须和 daemon 一致）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub state: String,
    pub child_pid: i32,
    pub cols: u16,
    pub rows: u16,
    pub ptsname: String,
    pub child_alive: bool,
    pub ring_buffer_bytes: u64,
    pub created_secs_ago: u64,
    pub last_active_secs_ago: u64,
    #[serde(default)]
    pub terminal_id: Option<u32>,
}

pub struct DaemonSession {
    pub session_id: String,
    pub pty_fd: RawFd,
    pub child_pid: i32,
    pub cols: u16,
    pub rows: u16,
    pub control_stream: UnixStream,
    pub shm_name: String,
}

impl Drop for DaemonSession {
    fn drop(&mut self) {
        eprintln!("[DaemonSession] drop session_id={}", self.session_id);
    }
}

// Protocol encoding/decoding

fn encode_message(msg: &Request) -> Result<Vec<u8>, String> {
    let json = serde_json::to_vec(msg).map_err(|e| format!("JSON encode: {}", e))?;
    let len = json.len() as u32;
    let mut buf = Vec::with_capacity(4 + json.len());
    buf.extend_from_slice(&len.to_be_bytes());
    buf.extend_from_slice(&json);
    Ok(buf)
}

fn try_decode_message(stream: &mut UnixStream) -> Result<Response, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .map_err(|e| format!("read length: {}", e))?;
    let len = u32::from_be_bytes(len_buf) as usize;

    let mut json_buf = vec![0u8; len];
    stream
        .read_exact(&mut json_buf)
        .map_err(|e| format!("read JSON: {}", e))?;

    serde_json::from_slice(&json_buf).map_err(|e| format!("JSON decode: {}", e))
}

// SCM_RIGHTS fd passing

fn recv_fd(stream: &UnixStream) -> Result<RawFd, String> {
    use libc::{c_void, iovec, msghdr, recvmsg, CMSG_DATA, CMSG_FIRSTHDR, SCM_RIGHTS};
    use std::mem;
    use std::os::unix::io::AsRawFd;

    let mut iov_buf = [0u8; 1];
    let mut iov = iovec {
        iov_base: iov_buf.as_mut_ptr() as *mut c_void,
        iov_len: 1,
    };

    let cmsg_space = unsafe { libc::CMSG_SPACE(mem::size_of::<RawFd>() as u32) as usize };
    let mut cmsg_buf = vec![0u8; cmsg_space];

    let mut msg: msghdr = unsafe { mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg_space as _;

    let ret = unsafe { recvmsg(stream.as_raw_fd(), &mut msg, 0) };
    if ret < 0 {
        return Err(format!("recvmsg failed: {}", std::io::Error::last_os_error()));
    }

    let cmsg = unsafe { CMSG_FIRSTHDR(&msg) };
    if cmsg.is_null() {
        return Err("no control message".to_string());
    }

    unsafe {
        if (*cmsg).cmsg_level != libc::SOL_SOCKET || (*cmsg).cmsg_type != SCM_RIGHTS {
            return Err("invalid control message type".to_string());
        }

        let data_ptr = CMSG_DATA(cmsg) as *const RawFd;
        if data_ptr.is_null() {
            return Err("null fd data pointer".to_string());
        }

        Ok(*data_ptr)
    }
}

// Helper functions

fn socket_path() -> String {
    env::var("PTY_DAEMON_SOCK").unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_string())
}

fn connect() -> Option<UnixStream> {
    UnixStream::connect(socket_path()).ok()
}

fn send_request(stream: &mut UnixStream, req: Request) -> Result<Response, String> {
    let encoded = encode_message(&req)?;
    stream
        .write_all(&encoded)
        .map_err(|e| format!("write request: {}", e))?;
    try_decode_message(stream)
}

// Public API

pub struct DaemonClient;

impl DaemonClient {
    pub fn ping() -> bool {
        let mut stream = match connect() {
            Some(s) => s,
            None => return false,
        };

        let req = Request::Ping;
        match send_request(&mut stream, req) {
            Ok(Response::Pong { .. }) => true,
            _ => false,
        }
    }

    pub fn create(
        cols: u16,
        rows: u16,
        cwd: Option<&str>,
        terminal_id: Option<u32>,
    ) -> Result<DaemonSession, String> {
        eprintln!("[DaemonClient] create: cols={}, rows={}, cwd={:?}, terminal_id={:?}", cols, rows, cwd, terminal_id);
        let mut stream = connect().ok_or_else(|| {
            let path = socket_path();
            let msg = format!("failed to connect to daemon at {}", path);
            eprintln!("[DaemonClient] {}", msg);
            msg
        })?;
        eprintln!("[DaemonClient] connected to daemon");

        // Step 1: Create session
        let create_req = Request::Create {
            shell: None,
            cols,
            rows,
            working_dir: cwd.map(|s| s.to_string()),
            terminal_id,
        };
        let session_id = match send_request(&mut stream, create_req) {
            Ok(Response::Created { session_id }) => {
                eprintln!("[DaemonClient] session created: {}", session_id);
                session_id
            }
            Ok(Response::Error { message }) => {
                eprintln!("[DaemonClient] daemon error: {}", message);
                return Err(message);
            }
            Ok(other) => {
                eprintln!("[DaemonClient] unexpected response: {:?}", other);
                return Err("unexpected response to Create".to_string());
            }
            Err(e) => {
                eprintln!("[DaemonClient] send_request failed: {}", e);
                return Err(e);
            }
        };

        // Step 2: Attach to the session (same connection!)
        Self::attach_on_stream(stream, session_id)
    }

    pub fn attach(session_id: &str) -> Result<DaemonSession, String> {
        let stream = connect().ok_or("failed to connect to daemon")?;
        Self::attach_on_stream(stream, session_id.to_string())
    }

    /// Attach 内部实现：发送 Attach 请求，接收 fd + ring data
    /// 接管 stream 所有权，存入 DaemonSession 用于崩溃检测
    fn attach_on_stream(
        mut stream: UnixStream,
        session_id: String,
    ) -> Result<DaemonSession, String> {
        let attach_req = Request::Attach {
            session_id: session_id.clone(),
        };
        let (cols, rows, child_pid, shm_name) = match send_request(&mut stream, attach_req)? {
            Response::AttachReady {
                cols,
                rows,
                child_pid,
                shm_name,
                ..
            } => (cols, rows, child_pid, shm_name),
            Response::AttachDeny { reason, .. } => return Err(format!("attach denied: {}", reason)),
            Response::Error { message } => return Err(message),
            _ => return Err("unexpected response to Attach".to_string()),
        };

        // Receive PTY fd via SCM_RIGHTS
        let pty_fd = recv_fd(&stream)?;

        use std::os::unix::io::AsRawFd;
        let control_fd = stream.as_raw_fd();
        eprintln!("[DaemonClient] attach done: control_fd={}, pty_fd={}, session={}, shm={}", control_fd, pty_fd, session_id, shm_name);

        Ok(DaemonSession {
            session_id,
            pty_fd,
            child_pid,
            cols,
            rows,
            control_stream: stream,
            shm_name,
        })
    }

    pub fn detach(session_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let mut stream = connect().ok_or("failed to connect to daemon")?;

        let detach_req = Request::Detach {
            session_id: session_id.to_string(),
            cols,
            rows,
        };
        match send_request(&mut stream, detach_req)? {
            Response::Detached { .. } => Ok(()),
            Response::Error { message } => Err(message),
            _ => Err("unexpected response to Detach".to_string()),
        }
    }

    pub fn list() -> Result<Vec<SessionInfo>, String> {
        let mut stream = connect().ok_or("failed to connect to daemon")?;

        let list_req = Request::List;
        match send_request(&mut stream, list_req)? {
            Response::SessionList { sessions } => Ok(sessions),
            Response::Error { message } => Err(message),
            _ => Err("unexpected response to List".to_string()),
        }
    }

    /// 主动关闭 tab 时 Kill daemon session（区分于崩溃的 crash detach）
    pub fn kill(session_id: &str) -> Result<(), String> {
        let mut stream = connect().ok_or("failed to connect to daemon")?;

        let req = Request::Kill {
            session_id: session_id.to_string(),
        };
        match send_request(&mut stream, req)? {
            Response::Killed { .. } => Ok(()),
            Response::Error { message } => Err(message),
            _ => Err("unexpected response to Kill".to_string()),
        }
    }

    /// 通知 daemon 更新 PTY 窗口大小（Attached 时 resize 走控制协议）
    pub fn winsize_update(session_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let mut stream = connect().ok_or("failed to connect to daemon")?;

        let req = Request::WinsizeUpdate {
            session_id: session_id.to_string(),
            cols,
            rows,
        };
        match send_request(&mut stream, req)? {
            Response::WinsizeUpdated { .. } => Ok(()),
            Response::Error { message } => Err(message),
            _ => Err("unexpected response to WinsizeUpdate".to_string()),
        }
    }
}
