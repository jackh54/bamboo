//! Helpers shared by the per-browser readers.

use std::{fs, io, path::Path};

use rusqlite::{Connection, OpenFlags};

use crate::{ImportError, ImportedBookmark};

const PERMISSION_HELP: &str = "allow access when macOS asks, or grant Bamboo Full Disk Access in System Settings ▸ Privacy & Security";

/// Milliseconds between 1601-01-01 (Chromium's epoch) and 1970-01-01.
const CHROMIUM_EPOCH_OFFSET_MS: i64 = 11_644_473_600_000;
/// Seconds between 1970-01-01 and 2001-01-01 (Core Data's epoch).
const CORE_DATA_EPOCH_OFFSET_S: f64 = 978_307_200.0;

impl From<rusqlite::Error> for ImportError {
    fn from(e: rusqlite::Error) -> Self {
        ImportError::Database {
            message: e.to_string(),
        }
    }
}

impl From<serde_json::Error> for ImportError {
    fn from(e: serde_json::Error) -> Self {
        ImportError::Parse {
            message: e.to_string(),
        }
    }
}

impl From<plist::Error> for ImportError {
    fn from(e: plist::Error) -> Self {
        ImportError::Parse {
            message: e.to_string(),
        }
    }
}

/// EPERM and EACCES both surface as `PermissionDenied`; on macOS that is
/// almost always TCC.
pub(crate) fn io_error(path: &Path, e: &io::Error) -> ImportError {
    let path_text = path.display().to_string();
    match e.kind() {
        io::ErrorKind::NotFound => ImportError::NotFound { path: path_text },
        io::ErrorKind::PermissionDenied => ImportError::PermissionDenied {
            path: path_text,
            message: PERMISSION_HELP.to_string(),
        },
        _ => ImportError::Io {
            message: format!("{path_text}: {e}"),
        },
    }
}

pub(crate) fn exists(path: &Path) -> Result<bool, ImportError> {
    match fs::metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(io_error(path, &e)),
    }
}

pub(crate) fn read(path: &Path) -> Result<Vec<u8>, ImportError> {
    fs::read(path).map_err(|e| io_error(path, &e))
}

/// `None` when the file does not exist.
pub(crate) fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, ImportError> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(io_error(path, &e)),
    }
}

/// Copies the database and its `-wal`, `-shm` and `-journal` files to a
/// temporary directory, opens the copy read-only and hands it to `read`. The
/// source browser may be running and holding locks on the original.
pub(crate) fn read_database<T>(
    path: &Path,
    read: impl FnOnce(&Connection) -> Result<T, ImportError>,
) -> Result<T, ImportError> {
    let copy_dir = tempfile::tempdir().map_err(|e| ImportError::Io {
        message: format!("could not create a temporary directory: {e}"),
    })?;
    let copy = copy_dir.path().join("db");
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut from = path.as_os_str().to_owned();
        from.push(suffix);
        let mut to = copy.as_os_str().to_owned();
        to.push(suffix);
        match fs::copy(&from, &to) {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound && !suffix.is_empty() => {}
            Err(e) => return Err(io_error(Path::new(&from), &e)),
        }
    }
    let db = Connection::open_with_flags(&copy, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    read(&db)
}

/// Chromium timestamps are microseconds since 1601-01-01; 0 means unset.
pub(crate) fn chromium_time_ms(microseconds: i64) -> Option<i64> {
    (microseconds != 0).then(|| microseconds / 1000 - CHROMIUM_EPOCH_OFFSET_MS)
}

pub(crate) fn core_data_time_ms(seconds: f64) -> i64 {
    ((seconds + CORE_DATA_EPOCH_OFFSET_S) * 1000.0) as i64
}

/// Appends a bookmark or folder and returns its `local_id`.
pub(crate) fn push_bookmark(
    bookmarks: &mut Vec<ImportedBookmark>,
    parent_local_id: Option<u32>,
    title: String,
    url: Option<String>,
    created_ms: Option<i64>,
) -> u32 {
    let local_id = bookmarks.len() as u32;
    bookmarks.push(ImportedBookmark {
        local_id,
        parent_local_id,
        title,
        url,
        created_ms,
    });
    local_id
}
