#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    Void,
    Float,
    Usize,
    /// Internal: result of a comparison. Not spellable in source.
    Bool,
    Ptr { is_const: bool, pointee: Box<Type> },
}

impl Type {
    pub fn display(&self) -> String {
        match self {
            Type::Void => "void".into(),
            Type::Float => "float".into(),
            Type::Usize => "usize".into(),
            Type::Bool => "bool".into(),
            Type::Ptr { is_const, pointee } => {
                format!("{}{} *", if *is_const { "const " } else { "" }, pointee.display())
            }
        }
    }

    pub fn is_numeric(&self) -> bool {
        matches!(self, Type::Float | Type::Usize)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Param {
    pub noalias: bool,
    pub ty: Type,
    pub name: String,
}

#[derive(Debug, Clone, Default)]
pub struct Contracts {
    pub effect: Option<Effect>,
    pub vectorize: Option<Vectorize>,
    pub fp_reassoc: bool,
}

impl Contracts {
    pub fn is_empty(&self) -> bool {
        self.effect.is_none() && self.vectorize.is_none() && !self.fp_reassoc
    }
}

#[derive(Debug, Clone)]
pub struct Effect {
    pub reads: Vec<String>,
    pub writes: Vec<String>,
    pub line: u32,
}

#[derive(Debug, Clone)]
pub struct Vectorize {
    pub require: bool,
    pub width: Option<u32>,
    pub line: u32,
}

#[derive(Debug, Clone)]
pub struct SelPart {
    pub label: String,
    pub param: Option<Param>,
}

#[derive(Debug, Clone)]
pub struct MethodSig {
    pub contracts: Contracts,
    pub ret: Type,
    pub parts: Vec<SelPart>,
    pub line: u32,
}

impl MethodSig {
    pub fn selector(&self) -> String {
        if self.parts.len() == 1 && self.parts[0].param.is_none() {
            self.parts[0].label.clone()
        } else {
            self.parts.iter().map(|p| format!("{}:", p.label)).collect()
        }
    }

    pub fn params(&self) -> impl Iterator<Item = &Param> {
        self.parts.iter().filter_map(|p| p.param.as_ref())
    }

    pub fn sig_matches(&self, other: &MethodSig) -> bool {
        self.ret == other.ret
            && self.parts.len() == other.parts.len()
            && self
                .parts
                .iter()
                .zip(&other.parts)
                .all(|(a, b)| a.label == b.label && a.param == b.param)
    }
}

#[derive(Debug, Clone)]
pub struct Interface {
    pub name: String,
    pub methods: Vec<MethodSig>,
    pub line: u32,
}

#[derive(Debug, Clone)]
pub struct MethodDef {
    pub sig: MethodSig,
    pub body: Vec<Stmt>,
}

#[derive(Debug, Clone)]
pub struct Implementation {
    pub name: String,
    pub methods: Vec<MethodDef>,
    pub line: u32,
}

#[derive(Debug, Default)]
pub struct Module {
    pub interfaces: Vec<Interface>,
    pub impls: Vec<Implementation>,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    Local { ty: Type, name: String, init: Expr, line: u32 },
    Assign { target: LValue, op: AssignOp, value: Expr, line: u32 },
    /// `for (usize var = init; cond; var++) { body }` — unit stride only.
    For { var: String, init: Expr, cond: Expr, body: Vec<Stmt>, line: u32 },
    Return { value: Option<Expr>, line: u32 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AssignOp {
    Set,
    Add,
}

#[derive(Debug, Clone)]
pub enum LValue {
    Var(String),
    Index { base: String, index: Expr },
}

#[derive(Debug, Clone)]
pub enum Expr {
    Int(u64),
    Float(f32),
    Var(String),
    Index { base: String, index: Box<Expr> },
    Bin { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,
}

impl BinOp {
    pub fn is_cmp(self) -> bool {
        matches!(self, BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge | BinOp::Eq | BinOp::Ne)
    }
}

pub fn expr_str(e: &Expr) -> String {
    match e {
        Expr::Int(v) => v.to_string(),
        Expr::Float(f) => format!("{}", f),
        Expr::Var(n) => n.clone(),
        Expr::Index { base, index } => format!("{}[{}]", base, expr_str(index)),
        Expr::Bin { op, lhs, rhs } => {
            let op = match op {
                BinOp::Add => "+",
                BinOp::Sub => "-",
                BinOp::Mul => "*",
                BinOp::Div => "/",
                BinOp::Lt => "<",
                BinOp::Le => "<=",
                BinOp::Gt => ">",
                BinOp::Ge => ">=",
                BinOp::Eq => "==",
                BinOp::Ne => "!=",
            };
            format!("{} {} {}", expr_str(lhs), op, expr_str(rhs))
        }
    }
}
