use rusqlite::Connection;

pub fn initialize(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS commands (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            command         TEXT NOT NULL,
            exit_code       INTEGER,
            start_ts        REAL,
            completed_ts    REAL,
            duration_ms     INTEGER,
            pwd             TEXT,
            shell           TEXT DEFAULT 'zsh',
            hostname        TEXT,
            git_branch      TEXT,
            terminal_id     TEXT,
            score           REAL DEFAULT 0,
            tier            INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_commands_command ON commands(command);
        CREATE INDEX IF NOT EXISTS idx_commands_pwd ON commands(pwd);
        CREATE INDEX IF NOT EXISTS idx_commands_start_ts ON commands(start_ts);
        CREATE INDEX IF NOT EXISTS idx_commands_terminal_id ON commands(terminal_id);",
    )
}
