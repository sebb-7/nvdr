//! The SSH process is intentionally only a framing proxy.  It has no TCC
//! ownership and no network listener; the signed FarRelay.app owns all macOS
//! permission checks and input injection in the logged-in user's session.

use std::{
    env, fs,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    thread,
};

pub const MAX_FRAME_BYTES: usize = 32 * 1024;

pub fn socket_path(home: Option<&str>) -> PathBuf {
    if let Some(path) = env::var_os("FARRELAY_HOST_SOCKET") {
        return PathBuf::from(path);
    }
    home.map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/nonexistent"))
        .join("Library/Application Support/FarRelay/farrelay-host.sock")
}

pub fn run() -> io::Result<()> {
    let home = env::var("HOME").ok();
    let path = socket_path(home.as_deref());
    let metadata = fs::metadata(&path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "FarRelay is not accepting local host connections ({})",
                path.display()
            ),
        )
    })?;
    if !metadata.file_type().is_socket() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refusing a non-socket local host endpoint",
        ));
    }
    let stream = UnixStream::connect(path)?;
    stream.set_nonblocking(false)?;
    let mut from_app = stream.try_clone()?;
    let output = thread::spawn(move || {
        let mut stdout = io::stdout().lock();
        io::copy(&mut from_app, &mut stdout).map(|_| ())
    });

    let mut stdin = io::stdin().lock();
    let mut to_app = stream;
    copy_bounded_ndjson(&mut stdin, &mut to_app)?;
    let _ = to_app.shutdown(std::net::Shutdown::Write);
    output
        .join()
        .map_err(|_| io::Error::other("local host output thread panicked"))??;
    Ok(())
}

fn copy_bounded_ndjson(input: &mut impl Read, output: &mut impl Write) -> io::Result<()> {
    let mut byte = [0_u8; 1];
    let mut frame = Vec::with_capacity(1024);
    loop {
        match input.read(&mut byte) {
            Ok(0) => return Ok(()),
            Ok(_) => {
                frame.push(byte[0]);
                if frame.len() > MAX_FRAME_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "host protocol frame exceeds 32 KiB",
                    ));
                }
                if byte[0] == b'\n' {
                    output.write_all(&frame)?;
                    output.flush()?;
                    frame.clear();
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_location_is_deterministic_and_per_user() {
        assert_eq!(
            socket_path(Some("/Users/tester")),
            PathBuf::from("/Users/tester/Library/Application Support/FarRelay/farrelay-host.sock")
        );
    }

    #[test]
    fn framing_forwards_complete_bounded_lines() {
        let mut output = Vec::new();
        copy_bounded_ndjson(&mut &b"one\ntwo\n"[..], &mut output).unwrap();
        assert_eq!(output, b"one\ntwo\n");
    }

    #[test]
    fn framing_rejects_an_unbounded_line() {
        let bytes = vec![b'x'; MAX_FRAME_BYTES + 1];
        let error = copy_bounded_ndjson(&mut bytes.as_slice(), &mut Vec::new()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }
}
