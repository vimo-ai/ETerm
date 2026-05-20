use super::db::ShellHistoryDb;
use super::types::CommandStart;

fn make_db() -> ShellHistoryDb {
    ShellHistoryDb::open_in_memory().unwrap()
}

#[test]
fn test_record_start_basic() {
    let db = make_db();
    let id = db
        .record_start(CommandStart {
            command: "cargo build".to_string(),
            cwd: Some("/Users/test/project".to_string()),
            git_branch: Some("main".to_string()),
            shell: "zsh".to_string(),
            terminal_id: "1".to_string(),
        })
        .unwrap();
    assert_eq!(id, 1);
}

#[test]
fn test_record_start_no_optional_fields() {
    let db = make_db();
    let id = db
        .record_start(CommandStart {
            command: "ls".to_string(),
            cwd: None,
            git_branch: None,
            shell: "zsh".to_string(),
            terminal_id: "2".to_string(),
        })
        .unwrap();
    assert_eq!(id, 1);
}

#[test]
fn test_record_finish_updates_exit_code_and_duration() {
    let db = make_db();
    db.record_start(CommandStart {
        command: "sleep 0".to_string(),
        cwd: Some("/tmp".to_string()),
        git_branch: None,
        shell: "zsh".to_string(),
        terminal_id: "3".to_string(),
    })
    .unwrap();

    db.record_finish("3", Some(0)).unwrap();

    let (exit_code, completed_ts, duration_ms): (Option<i32>, Option<f64>, Option<i64>) = db
        .conn
        .query_row(
            "SELECT exit_code, completed_ts, duration_ms FROM commands WHERE terminal_id = '3'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();

    assert_eq!(exit_code, Some(0));
    assert!(completed_ts.is_some());
    assert!(duration_ms.is_some());
}

#[test]
fn test_record_finish_matches_latest_unfinished() {
    let db = make_db();

    db.record_start(CommandStart {
        command: "echo first".to_string(),
        cwd: None,
        git_branch: None,
        shell: "zsh".to_string(),
        terminal_id: "4".to_string(),
    })
    .unwrap();
    db.record_finish("4", Some(0)).unwrap();

    db.record_start(CommandStart {
        command: "echo second".to_string(),
        cwd: None,
        git_branch: None,
        shell: "zsh".to_string(),
        terminal_id: "4".to_string(),
    })
    .unwrap();
    db.record_finish("4", Some(1)).unwrap();

    let results: Vec<(String, Option<i32>)> = {
        let mut stmt = db
            .conn
            .prepare("SELECT command, exit_code FROM commands WHERE terminal_id = '4' ORDER BY id")
            .unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };

    assert_eq!(results.len(), 2);
    assert_eq!(results[0], ("echo first".to_string(), Some(0)));
    assert_eq!(results[1], ("echo second".to_string(), Some(1)));
}

#[test]
fn test_record_finish_wrong_terminal_id_no_effect() {
    let db = make_db();
    db.record_start(CommandStart {
        command: "test".to_string(),
        cwd: None,
        git_branch: None,
        shell: "zsh".to_string(),
        terminal_id: "5".to_string(),
    })
    .unwrap();

    db.record_finish("999", Some(0)).unwrap();

    let exit_code: Option<i32> = db
        .conn
        .query_row(
            "SELECT exit_code FROM commands WHERE terminal_id = '5'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(exit_code, None);
}

#[test]
fn test_record_finish_exit_code_none() {
    let db = make_db();
    db.record_start(CommandStart {
        command: "killed".to_string(),
        cwd: None,
        git_branch: None,
        shell: "zsh".to_string(),
        terminal_id: "6".to_string(),
    })
    .unwrap();

    db.record_finish("6", None).unwrap();

    let exit_code: Option<i32> = db
        .conn
        .query_row(
            "SELECT exit_code FROM commands WHERE terminal_id = '6'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    // exit_code is NULL because we passed None
    assert_eq!(exit_code, None);
}

#[test]
fn test_multiple_terminals_independent() {
    let db = make_db();

    db.record_start(CommandStart {
        command: "cmd_a".to_string(),
        cwd: Some("/a".to_string()),
        git_branch: Some("feat-a".to_string()),
        shell: "zsh".to_string(),
        terminal_id: "10".to_string(),
    })
    .unwrap();

    db.record_start(CommandStart {
        command: "cmd_b".to_string(),
        cwd: Some("/b".to_string()),
        git_branch: Some("feat-b".to_string()),
        shell: "zsh".to_string(),
        terminal_id: "11".to_string(),
    })
    .unwrap();

    db.record_finish("11", Some(0)).unwrap();
    db.record_finish("10", Some(127)).unwrap();

    let exit_a: Option<i32> = db
        .conn
        .query_row(
            "SELECT exit_code FROM commands WHERE terminal_id = '10'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let exit_b: Option<i32> = db
        .conn
        .query_row(
            "SELECT exit_code FROM commands WHERE terminal_id = '11'",
            [],
            |r| r.get(0),
        )
        .unwrap();

    assert_eq!(exit_a, Some(127));
    assert_eq!(exit_b, Some(0));
}

#[test]
fn test_eviction_over_10k() {
    let db = make_db();

    for i in 0..10_005 {
        db.record_start(CommandStart {
            command: format!("cmd_{}", i),
            cwd: None,
            git_branch: None,
            shell: "zsh".to_string(),
            terminal_id: "7".to_string(),
        })
        .unwrap();
        db.record_finish("7", Some(0)).unwrap();
    }

    let count: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM commands", [], |r| r.get(0))
        .unwrap();
    assert!(count <= 10_000, "Expected <= 10000, got {}", count);
}

#[test]
fn test_git_branch_stored_correctly() {
    let db = make_db();
    db.record_start(CommandStart {
        command: "git push".to_string(),
        cwd: Some("/repo".to_string()),
        git_branch: Some("feature/shell-history".to_string()),
        shell: "zsh".to_string(),
        terminal_id: "8".to_string(),
    })
    .unwrap();

    let branch: Option<String> = db
        .conn
        .query_row(
            "SELECT git_branch FROM commands WHERE terminal_id = '8'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(branch, Some("feature/shell-history".to_string()));
}
