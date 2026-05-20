pub struct CommandStart {
    pub command: String,
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
    pub shell: String,
    pub terminal_id: String,
}
