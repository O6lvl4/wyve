use crate::ast::*;
use crate::diag::Diag;
use crate::lexer::{Tok, Token};

pub fn parse(toks: Vec<Token>) -> Result<Module, Diag> {
    let mut p = Parser { toks, pos: 0 };
    p.module()
}

struct Parser {
    toks: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> &Tok {
        &self.toks[self.pos].tok
    }

    fn line(&self) -> u32 {
        self.toks[self.pos].line
    }

    fn bump(&mut self) -> Tok {
        let t = self.toks[self.pos].tok.clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }

    fn eat(&mut self, t: &Tok) -> bool {
        if self.peek() == t {
            self.bump();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, t: Tok, what: &str) -> Result<(), Diag> {
        if self.peek() == &t {
            self.bump();
            Ok(())
        } else {
            Err(Diag::err(None, format!("expected {}", what), self.line()))
        }
    }

    fn expect_ident(&mut self, what: &str) -> Result<String, Diag> {
        if let Tok::Ident(s) = self.peek().clone() {
            self.bump();
            Ok(s)
        } else {
            Err(Diag::err(None, format!("expected {}", what), self.line()))
        }
    }

    fn module(&mut self) -> Result<Module, Diag> {
        let mut m = Module::default();
        loop {
            match self.peek().clone() {
                Tok::At(s) if s == "interface" => m.interfaces.push(self.interface()?),
                Tok::At(s) if s == "implementation" => m.impls.push(self.implementation()?),
                Tok::Eof => break,
                _ => {
                    return Err(Diag::err(
                        None,
                        "expected `@interface` or `@implementation` at top level",
                        self.line(),
                    ))
                }
            }
        }
        Ok(m)
    }

    fn interface(&mut self) -> Result<Interface, Diag> {
        let line = self.line();
        self.bump(); // @interface
        let name = self.expect_ident("interface name")?;
        let mut methods = Vec::new();
        loop {
            if let Tok::At(s) = self.peek() {
                if s == "end" {
                    self.bump();
                    break;
                }
            }
            if self.peek() == &Tok::Eof {
                return Err(Diag::err(None, "unterminated @interface (missing @end)", self.line()));
            }
            let contracts = self.contracts()?;
            let mut sig = self.method_sig()?;
            sig.contracts = contracts;
            self.expect(Tok::Semi, "`;` after method declaration")?;
            methods.push(sig);
        }
        Ok(Interface { name, methods, line })
    }

    fn implementation(&mut self) -> Result<Implementation, Diag> {
        let line = self.line();
        self.bump(); // @implementation
        let name = self.expect_ident("implementation name")?;
        let mut methods = Vec::new();
        loop {
            if let Tok::At(s) = self.peek() {
                if s == "end" {
                    self.bump();
                    break;
                }
            }
            if self.peek() == &Tok::Eof {
                return Err(Diag::err(None, "unterminated @implementation (missing @end)", self.line()));
            }
            let cline = self.line();
            let contracts = self.contracts()?;
            if !contracts.is_empty() {
                return Err(Diag::err(
                    None,
                    "contracts belong on the @interface declaration, not the @implementation",
                    cline,
                ));
            }
            let sig = self.method_sig()?;
            self.expect(Tok::LBrace, "`{` to begin method body")?;
            let body = self.block()?;
            methods.push(MethodDef { sig, body });
        }
        Ok(Implementation { name, methods, line })
    }

    fn contracts(&mut self) -> Result<Contracts, Diag> {
        let mut c = Contracts::default();
        loop {
            let line = self.line();
            match self.peek().clone() {
                Tok::At(s) if s == "effect" => {
                    self.bump();
                    self.expect(Tok::LParen, "`(` after @effect")?;
                    let mut eff = Effect { reads: vec![], writes: vec![], line };
                    loop {
                        let kind = self.expect_ident("`reads` or `writes`")?;
                        self.expect(Tok::LParen, "`(`")?;
                        let mut names = Vec::new();
                        loop {
                            names.push(self.expect_ident("parameter name")?);
                            if !self.eat(&Tok::Comma) {
                                break;
                            }
                        }
                        self.expect(Tok::RParen, "`)`")?;
                        match kind.as_str() {
                            "reads" => eff.reads.extend(names),
                            "writes" => eff.writes.extend(names),
                            _ => {
                                return Err(Diag::err(
                                    None,
                                    format!("unknown effect clause `{}` (expected `reads` or `writes`)", kind),
                                    line,
                                ))
                            }
                        }
                        if !self.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    self.expect(Tok::RParen, "`)` to close @effect")?;
                    c.effect = Some(eff);
                }
                Tok::At(s) if s == "vectorize" => {
                    self.bump();
                    self.expect(Tok::LParen, "`(` after @vectorize")?;
                    let mut v = Vectorize { require: false, width: None, line };
                    loop {
                        let item = self.expect_ident("`require` or `width`")?;
                        match item.as_str() {
                            "require" => v.require = true,
                            "width" => {
                                self.expect(Tok::Colon, "`:` after `width`")?;
                                if let Tok::Int(n) = self.peek().clone() {
                                    self.bump();
                                    v.width = Some(n as u32);
                                } else {
                                    return Err(Diag::err(None, "expected integer width", self.line()));
                                }
                            }
                            _ => {
                                return Err(Diag::err(
                                    None,
                                    format!("unknown @vectorize item `{}` (expected `require` or `width`)", item),
                                    line,
                                ))
                            }
                        }
                        if !self.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    self.expect(Tok::RParen, "`)` to close @vectorize")?;
                    c.vectorize = Some(v);
                }
                Tok::At(s) if s == "fp" => {
                    self.bump();
                    self.expect(Tok::LParen, "`(` after @fp")?;
                    let flag = self.expect_ident("fp flag")?;
                    if flag != "reassoc" {
                        return Err(Diag::err(None, format!("unknown fp flag `{}` (expected `reassoc`)", flag), line));
                    }
                    self.expect(Tok::RParen, "`)` to close @fp")?;
                    c.fp_reassoc = true;
                }
                _ => break,
            }
        }
        Ok(c)
    }

    fn method_sig(&mut self) -> Result<MethodSig, Diag> {
        let line = self.line();
        if !self.eat(&Tok::Plus) {
            return Err(Diag::err(
                None,
                "expected `+` (kernels are class methods; instance methods are not part of stage 0)",
                line,
            ));
        }
        self.expect(Tok::LParen, "`(` before return type")?;
        let ret = self.base_type()?;
        if self.peek() == &Tok::Star {
            return Err(Diag::err(None, "pointer return types are not part of stage 0", self.line()));
        }
        self.expect(Tok::RParen, "`)` after return type")?;
        let first = self.expect_ident("selector")?;
        let mut parts = Vec::new();
        if self.eat(&Tok::Colon) {
            let param = self.param()?;
            parts.push(SelPart { label: first, param: Some(param) });
            while let Tok::Ident(label) = self.peek().clone() {
                self.bump();
                self.expect(Tok::Colon, "`:` after selector label")?;
                let param = self.param()?;
                parts.push(SelPart { label, param: Some(param) });
            }
        } else {
            parts.push(SelPart { label: first, param: None });
        }
        Ok(MethodSig { contracts: Contracts::default(), ret, parts, line })
    }

    fn param(&mut self) -> Result<Param, Diag> {
        let line = self.line();
        self.expect(Tok::LParen, "`(` before parameter type")?;
        let mut noalias = false;
        if let Tok::At(s) = self.peek().clone() {
            if s == "noalias" {
                self.bump();
                noalias = true;
            } else {
                return Err(Diag::err(None, format!("unknown type qualifier `@{}`", s), self.line()));
            }
        }
        let is_const = self.eat(&Tok::KwConst);
        let base = self.base_type()?;
        let ty = if self.eat(&Tok::Star) {
            Type::Ptr { is_const, pointee: Box::new(base) }
        } else {
            if is_const {
                return Err(Diag::err(None, "`const` on a by-value parameter has no meaning in Wyve", line));
            }
            if matches!(base, Type::Void) {
                return Err(Diag::err(None, "parameter cannot be void", line));
            }
            base
        };
        if noalias && !matches!(ty, Type::Ptr { .. }) {
            return Err(Diag::err(None, "@noalias applies only to pointer parameters", line));
        }
        self.expect(Tok::RParen, "`)` after parameter type")?;
        let name = self.expect_ident("parameter name")?;
        Ok(Param { noalias, ty, name })
    }

    fn base_type(&mut self) -> Result<Type, Diag> {
        match self.peek().clone() {
            Tok::KwFloat => {
                self.bump();
                Ok(Type::Float)
            }
            Tok::KwUsize => {
                self.bump();
                Ok(Type::Usize)
            }
            Tok::KwVoid => {
                self.bump();
                Ok(Type::Void)
            }
            _ => Err(Diag::err(None, "expected a type (`float`, `usize`, `void`)", self.line())),
        }
    }

    /// Assumes `{` already consumed; consumes through the matching `}`.
    fn block(&mut self) -> Result<Vec<Stmt>, Diag> {
        let mut stmts = Vec::new();
        loop {
            if self.eat(&Tok::RBrace) {
                break;
            }
            if self.peek() == &Tok::Eof {
                return Err(Diag::err(None, "unterminated block (missing `}`)", self.line()));
            }
            stmts.push(self.stmt()?);
        }
        Ok(stmts)
    }

    fn stmt(&mut self) -> Result<Stmt, Diag> {
        let line = self.line();
        match self.peek().clone() {
            Tok::KwFloat | Tok::KwUsize => {
                let ty = self.base_type()?;
                let name = self.expect_ident("variable name")?;
                self.expect(Tok::Assign, "`=` (locals must be initialized)")?;
                let init = self.expr()?;
                self.expect(Tok::Semi, "`;`")?;
                Ok(Stmt::Local { ty, name, init, line })
            }
            Tok::KwFor => {
                self.bump();
                self.expect(Tok::LParen, "`(` after `for`")?;
                if !self.eat(&Tok::KwUsize) {
                    return Err(Diag::err(None, "loop induction variable must be `usize`", self.line()));
                }
                let var = self.expect_ident("induction variable")?;
                self.expect(Tok::Assign, "`=`")?;
                let init = self.expr()?;
                self.expect(Tok::Semi, "`;`")?;
                let cond = self.expr()?;
                self.expect(Tok::Semi, "`;`")?;
                let step = self.expect_ident("induction variable in step")?;
                if step != var {
                    return Err(Diag::err(
                        None,
                        format!("step must increment the induction variable `{}`", var),
                        self.line(),
                    ));
                }
                self.expect(Tok::PlusPlus, "`++` (stage 0 supports unit-stride loops only)")?;
                self.expect(Tok::RParen, "`)`")?;
                self.expect(Tok::LBrace, "`{`")?;
                let body = self.block()?;
                Ok(Stmt::For { var, init, cond, body, line })
            }
            Tok::KwReturn => {
                self.bump();
                let value = if self.peek() == &Tok::Semi { None } else { Some(self.expr()?) };
                self.expect(Tok::Semi, "`;`")?;
                Ok(Stmt::Return { value, line })
            }
            Tok::Ident(name) => {
                self.bump();
                let target = if self.eat(&Tok::LBracket) {
                    let idx = self.expr()?;
                    self.expect(Tok::RBracket, "`]`")?;
                    LValue::Index { base: name, index: idx }
                } else {
                    LValue::Var(name)
                };
                let op = if self.eat(&Tok::PlusEq) {
                    AssignOp::Add
                } else if self.eat(&Tok::Assign) {
                    AssignOp::Set
                } else {
                    return Err(Diag::err(None, "expected `=` or `+=`", self.line()));
                };
                let value = self.expr()?;
                self.expect(Tok::Semi, "`;`")?;
                Ok(Stmt::Assign { target, op, value, line })
            }
            _ => Err(Diag::err(None, "expected a statement", line)),
        }
    }

    fn expr(&mut self) -> Result<Expr, Diag> {
        let lhs = self.add_expr()?;
        let op = match self.peek() {
            Tok::Lt => BinOp::Lt,
            Tok::Le => BinOp::Le,
            Tok::Gt => BinOp::Gt,
            Tok::Ge => BinOp::Ge,
            Tok::EqEq => BinOp::Eq,
            Tok::Ne => BinOp::Ne,
            _ => return Ok(lhs),
        };
        self.bump();
        let rhs = self.add_expr()?;
        Ok(Expr::Bin { op, lhs: Box::new(lhs), rhs: Box::new(rhs) })
    }

    fn add_expr(&mut self) -> Result<Expr, Diag> {
        let mut lhs = self.mul_expr()?;
        loop {
            let op = match self.peek() {
                Tok::Plus => BinOp::Add,
                Tok::Minus => BinOp::Sub,
                _ => break,
            };
            self.bump();
            let rhs = self.mul_expr()?;
            lhs = Expr::Bin { op, lhs: Box::new(lhs), rhs: Box::new(rhs) };
        }
        Ok(lhs)
    }

    fn mul_expr(&mut self) -> Result<Expr, Diag> {
        let mut lhs = self.primary()?;
        loop {
            let op = match self.peek() {
                Tok::Star => BinOp::Mul,
                Tok::Slash => BinOp::Div,
                _ => break,
            };
            self.bump();
            let rhs = self.primary()?;
            lhs = Expr::Bin { op, lhs: Box::new(lhs), rhs: Box::new(rhs) };
        }
        Ok(lhs)
    }

    fn primary(&mut self) -> Result<Expr, Diag> {
        match self.peek().clone() {
            Tok::Int(v) => {
                self.bump();
                Ok(Expr::Int(v))
            }
            Tok::Float(v) => {
                self.bump();
                Ok(Expr::Float(v))
            }
            Tok::Ident(name) => {
                self.bump();
                if self.eat(&Tok::LBracket) {
                    let idx = self.expr()?;
                    self.expect(Tok::RBracket, "`]`")?;
                    Ok(Expr::Index { base: name, index: Box::new(idx) })
                } else {
                    Ok(Expr::Var(name))
                }
            }
            Tok::LParen => {
                self.bump();
                let e = self.expr()?;
                self.expect(Tok::RParen, "`)`")?;
                Ok(e)
            }
            _ => Err(Diag::err(None, "expected an expression", self.line())),
        }
    }
}
