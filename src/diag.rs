#[derive(Debug, Clone)]
pub struct Diag {
    pub code: Option<&'static str>,
    pub msg: String,
    pub line: u32,
    pub notes: Vec<String>,
}

impl Diag {
    pub fn err(code: Option<&'static str>, msg: impl Into<String>, line: u32) -> Self {
        Diag { code, msg: msg.into(), line, notes: Vec::new() }
    }

    pub fn note(mut self, n: impl Into<String>) -> Self {
        self.notes.push(n.into());
        self
    }

    pub fn render(&self, file: &str) -> String {
        let mut s = match self.code {
            Some(c) => format!("error[{}]: {}\n", c, self.msg),
            None => format!("error: {}\n", self.msg),
        };
        s.push_str(&format!("  --> {}:{}\n", file, self.line));
        for n in &self.notes {
            s.push_str(&format!("note: {}\n", n));
        }
        s
    }
}
