use rusqlite::Connection;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use super::schema;
use super::types::CommandStart;

static INSTANCE: OnceLock<Arc<Mutex<ShellHistoryDb>>> = OnceLock::new();

pub struct ShellHistoryDb {
    pub(crate) conn: Connection,
}

impl ShellHistoryDb {
    pub fn global() -> &'static Arc<Mutex<ShellHistoryDb>> {
        INSTANCE.get_or_init(|| {
            let db = Self::open().unwrap_or_else(|e| {
                eprintln!("[shell-history] Failed to open DB: {:?}", e);
                panic!("shell-history DB init failed");
            });
            Arc::new(Mutex::new(db))
        })
    }

    pub fn try_global() -> Option<&'static Arc<Mutex<ShellHistoryDb>>> {
        match std::panic::catch_unwind(|| Self::global()) {
            Ok(db) => Some(db),
            Err(_) => None,
        }
    }

    fn open() -> rusqlite::Result<Self> {
        let db_path = Self::db_path();
        if let Some(parent) = db_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        Self::open_at(&db_path)
    }

    pub(crate) fn open_in_memory() -> rusqlite::Result<Self> {
        let conn = Connection::open_in_memory()?;
        schema::initialize(&conn)?;
        Ok(Self { conn })
    }

    fn open_at(path: &std::path::Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")?;
        schema::initialize(&conn)?;
        Ok(Self { conn })
    }

    pub fn record_start(&self, entry: CommandStart) -> rusqlite::Result<i64> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        self.conn.execute(
            "INSERT INTO commands (command, start_ts, pwd, shell, git_branch, terminal_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                entry.command,
                now,
                entry.cwd,
                entry.shell,
                entry.git_branch,
                entry.terminal_id,
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn record_finish(&self, terminal_id: &str, exit_code: Option<u8>) -> rusqlite::Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        self.conn.execute(
            "UPDATE commands
             SET exit_code = ?1,
                 completed_ts = ?2,
                 duration_ms = CAST((?2 - start_ts) * 1000 AS INTEGER)
             WHERE id = (
                 SELECT id FROM commands
                 WHERE terminal_id = ?3 AND exit_code IS NULL
                 ORDER BY id DESC LIMIT 1
             )",
            rusqlite::params![exit_code.map(|c| c as i32), now, terminal_id],
        )?;

        self.maybe_evict()?;
        Ok(())
    }

    fn maybe_evict(&self) -> rusqlite::Result<()> {
        let count: i64 =
            self.conn.query_row("SELECT COUNT(*) FROM commands", [], |r| r.get(0))?;
        if count > 10_000 {
            let excess = count - 10_000;
            self.conn.execute(
                "DELETE FROM commands WHERE id IN (
                    SELECT id FROM commands WHERE tier = 0
                    ORDER BY id ASC LIMIT ?1
                )",
                [excess],
            )?;
        }
        Ok(())
    }

    fn db_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home).join(".vimo/db/shell-history.db")
    }
}
