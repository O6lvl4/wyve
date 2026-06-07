//! Contract verification. This is the part of the compiler that makes the
//! contracts *proven, not promised*:
//!
//! - signatures in @implementation must match their @interface declaration
//! - @effect(reads/writes) is checked against every access in the body
//! - @vectorize(require) runs wyvec's own dependence analysis over the
//!   restricted (affine, unit-stride) loop form — legality is decided here,
//!   by the language, not by whatever LLVM happens to do this release.

use crate::ast::*;
use crate::diag::Diag;
use std::collections::{HashMap, HashSet};

pub struct Kernel<'a> {
    pub iface: &'a str,
    pub decl: &'a MethodSig,
    pub def: &'a MethodDef,
    pub symbol: String,
}

pub fn check(module: &Module) -> Result<Vec<Kernel<'_>>, Vec<Diag>> {
    let mut diags = Vec::new();
    let mut kernels = Vec::new();

    let ifaces: HashMap<&str, &Interface> =
        module.interfaces.iter().map(|i| (i.name.as_str(), i)).collect();

    for imp in &module.impls {
        let Some(iface) = ifaces.get(imp.name.as_str()).copied() else {
            diags.push(Diag::err(
                None,
                format!("no @interface named `{}` for this @implementation", imp.name),
                imp.line,
            ));
            continue;
        };
        for def in &imp.methods {
            let sel = def.sig.selector();
            let Some(decl) = iface.methods.iter().find(|m| m.selector() == sel) else {
                diags.push(
                    Diag::err(
                        Some("WVN001"),
                        format!(
                            "kernel `{}` has no contract surface: no matching declaration in @interface {}",
                            sel, iface.name
                        ),
                        def.sig.line,
                    )
                    .note(format!("@interface {} begins at line {}", iface.name, iface.line)),
                );
                continue;
            };
            if !decl.sig_matches(&def.sig) {
                diags.push(
                    Diag::err(
                        Some("WVN002"),
                        format!("signature of `{}` does not match its declaration in @interface {}", sel, iface.name),
                        def.sig.line,
                    )
                    .note(format!("declared at line {}", decl.line)),
                );
                continue;
            }
            let mut k_diags = check_kernel(&iface.name, decl, def);
            if k_diags.is_empty() {
                let symbol = format!("{}_{}", iface.name, def.sig.parts[0].label);
                kernels.push(Kernel { iface: &iface.name, decl, def, symbol });
            } else {
                diags.append(&mut k_diags);
            }
        }
    }

    // mangling is `<Interface>_<first-label>`: reject collisions early
    let mut seen = HashSet::new();
    for k in &kernels {
        if !seen.insert(k.symbol.clone()) {
            diags.push(Diag::err(
                None,
                format!("mangled symbol `{}` collides with another kernel (stage 0 mangles by first selector label)", k.symbol),
                k.def.sig.line,
            ));
        }
    }

    if diags.is_empty() {
        Ok(kernels)
    } else {
        Err(diags)
    }
}

fn check_kernel(iface: &str, decl: &MethodSig, def: &MethodDef) -> Vec<Diag> {
    let mut diags = Vec::new();
    let params: HashMap<&str, &Param> = decl.params().map(|p| (p.name.as_str(), p)).collect();

    if let Some(eff) = &decl.contracts.effect {
        for n in eff.reads.iter().chain(&eff.writes) {
            match params.get(n.as_str()).copied() {
                Some(p) if matches!(p.ty, Type::Ptr { .. }) => {}
                Some(_) => diags.push(Diag::err(
                    None,
                    format!("effect contract names `{}`, which is not a pointer parameter", n),
                    eff.line,
                )),
                None => diags.push(Diag::err(
                    None,
                    format!("effect contract names unknown parameter `{}`", n),
                    eff.line,
                )),
            }
        }
    }

    {
        let mut tc = TypeCk {
            params: &params,
            locals: Vec::new(),
            declared: HashSet::new(),
            ret: &decl.ret,
            diags: &mut diags,
        };
        tc.block(&def.body);
    }
    if decl.ret != Type::Void && !matches!(def.body.last(), Some(Stmt::Return { .. })) {
        diags.push(Diag::err(
            None,
            format!("kernel returns `{}` but does not end with a return statement", decl.ret.display()),
            def.sig.line,
        ));
    }
    if !diags.is_empty() {
        return diags;
    }

    if let Some(eff) = &decl.contracts.effect {
        effect_check(iface, eff, &params, &def.body, &mut diags);
    }
    if let Some(v) = &decl.contracts.vectorize {
        if v.require {
            vectorize_check(decl, def, &params, v, &mut diags);
        }
    }
    diags
}

// ---------------------------------------------------------------- type check

struct TypeCk<'a> {
    params: &'a HashMap<&'a str, &'a Param>,
    locals: Vec<(String, Type)>,
    /// stage 0: one declaration per name across the whole kernel,
    /// so codegen can give every local a single alloca slot.
    declared: HashSet<String>,
    ret: &'a Type,
    diags: &'a mut Vec<Diag>,
}

impl TypeCk<'_> {
    fn lookup(&self, name: &str) -> Option<Type> {
        if let Some(p) = self.params.get(name).copied() {
            return Some(p.ty.clone());
        }
        self.locals.iter().rev().find(|(n, _)| n == name).map(|(_, t)| t.clone())
    }

    fn declare(&mut self, name: &str, ty: Type, line: u32) {
        if self.params.contains_key(name) || !self.declared.insert(name.to_string()) {
            self.diags.push(Diag::err(
                None,
                format!("`{}` is already defined (stage 0 allows one declaration per name)", name),
                line,
            ));
        }
        self.locals.push((name.to_string(), ty));
    }

    fn block(&mut self, stmts: &[Stmt]) {
        let depth = self.locals.len();
        for s in stmts {
            self.stmt(s);
        }
        self.locals.truncate(depth);
    }

    fn stmt(&mut self, s: &Stmt) {
        match s {
            Stmt::Local { ty, name, init, line } => {
                if let Some(t) = self.infer(init, *line) {
                    if &t != ty {
                        self.diags.push(Diag::err(
                            None,
                            format!("initializer type `{}` does not match `{}`", t.display(), ty.display()),
                            *line,
                        ));
                    }
                }
                self.declare(name, ty.clone(), *line);
            }
            Stmt::Assign { target, op, value, line } => {
                let tty = match target {
                    LValue::Var(n) => {
                        if self.params.contains_key(n.as_str()) {
                            self.diags.push(Diag::err(None, format!("cannot assign to parameter `{}`", n), *line));
                            return;
                        }
                        match self.lookup(n) {
                            Some(t) => t,
                            None => {
                                self.diags.push(Diag::err(None, format!("`{}` is not defined", n), *line));
                                return;
                            }
                        }
                    }
                    LValue::Index { base, index } => {
                        let Some(p) = self.params.get(base.as_str()).copied() else {
                            self.diags.push(Diag::err(None, format!("`{}` is not a pointer parameter", base), *line));
                            return;
                        };
                        let Type::Ptr { is_const, pointee } = &p.ty else {
                            self.diags.push(Diag::err(
                                None,
                                format!("`{}` is not a pointer and cannot be indexed", base),
                                *line,
                            ));
                            return;
                        };
                        if *is_const {
                            self.diags.push(Diag::err(
                                None,
                                format!("cannot write through `{}`: it is a const pointer", base),
                                *line,
                            ));
                        }
                        if let Some(it) = self.infer(index, *line) {
                            if it != Type::Usize {
                                self.diags.push(Diag::err(None, "subscript must be `usize`", *line));
                            }
                        }
                        (**pointee).clone()
                    }
                };
                if let Some(vt) = self.infer(value, *line) {
                    if vt != tty {
                        self.diags.push(Diag::err(
                            None,
                            format!("cannot assign `{}` to `{}`", vt.display(), tty.display()),
                            *line,
                        ));
                    }
                }
                if *op == AssignOp::Add && !tty.is_numeric() {
                    self.diags.push(Diag::err(None, "`+=` requires a numeric target", *line));
                }
            }
            Stmt::For { var, init, cond, body, line } => {
                if let Some(t) = self.infer(init, *line) {
                    if t != Type::Usize {
                        self.diags.push(Diag::err(None, "loop bounds must be `usize`", *line));
                    }
                }
                let depth = self.locals.len();
                self.declare(var, Type::Usize, *line);
                match cond {
                    Expr::Bin { op, .. } if op.is_cmp() => {
                        self.infer(cond, *line);
                    }
                    _ => self.diags.push(Diag::err(None, "loop condition must be a comparison", *line)),
                }
                self.block(body);
                self.locals.truncate(depth);
            }
            Stmt::Return { value, line } => {
                let vt = match value {
                    Some(e) => self.infer(e, *line),
                    None => Some(Type::Void),
                };
                if let Some(vt) = vt {
                    if &vt != self.ret {
                        self.diags.push(Diag::err(
                            None,
                            format!(
                                "return type `{}` does not match kernel return type `{}`",
                                vt.display(),
                                self.ret.display()
                            ),
                            *line,
                        ));
                    }
                }
            }
        }
    }

    fn infer(&mut self, e: &Expr, line: u32) -> Option<Type> {
        match e {
            Expr::Int(_) => Some(Type::Usize),
            Expr::Float(_) => Some(Type::Float),
            Expr::Var(n) => match self.lookup(n) {
                Some(t) => Some(t),
                None => {
                    self.diags.push(Diag::err(None, format!("`{}` is not defined", n), line));
                    None
                }
            },
            Expr::Index { base, index } => {
                let Some(p) = self.params.get(base.as_str()).copied() else {
                    self.diags.push(Diag::err(None, format!("`{}` is not a pointer parameter", base), line));
                    return None;
                };
                let Type::Ptr { pointee, .. } = &p.ty else {
                    self.diags.push(Diag::err(
                        None,
                        format!("`{}` is not a pointer and cannot be indexed", base),
                        line,
                    ));
                    return None;
                };
                if let Some(it) = self.infer(index, line) {
                    if it != Type::Usize {
                        self.diags.push(Diag::err(None, "subscript must be `usize`", line));
                    }
                }
                Some((**pointee).clone())
            }
            Expr::Bin { op, lhs, rhs } => {
                let lt = self.infer(lhs, line)?;
                let rt = self.infer(rhs, line)?;
                if lt != rt {
                    self.diags.push(Diag::err(
                        None,
                        format!("type mismatch: `{}` vs `{}`", lt.display(), rt.display()),
                        line,
                    ));
                    return None;
                }
                if !lt.is_numeric() {
                    self.diags.push(Diag::err(None, "operands must be numeric", line));
                    return None;
                }
                if op.is_cmp() {
                    Some(Type::Bool)
                } else {
                    Some(lt)
                }
            }
        }
    }
}

// --------------------------------------------------------------- effect check

fn effect_check(
    iface: &str,
    eff: &Effect,
    params: &HashMap<&str, &Param>,
    body: &[Stmt],
    diags: &mut Vec<Diag>,
) {
    let mut accesses: Vec<(String, bool, u32)> = Vec::new();
    collect_accesses(body, &mut accesses);
    let mut reported: HashSet<(String, bool)> = HashSet::new();
    for (p, is_write, line) in &accesses {
        if !params.contains_key(p.as_str()) {
            continue;
        }
        if *is_write && !eff.writes.iter().any(|w| w == p) {
            if reported.insert((p.clone(), true)) {
                let msg = if eff.reads.iter().any(|r| r == p) {
                    format!("effect violation: `{}` is written, but the contract declares only reads({})", p, p)
                } else {
                    format!("effect violation: `{}` is written, but the contract does not declare writes({})", p, p)
                };
                diags.push(
                    Diag::err(Some("WVN003"), msg, *line).note(format!("contract declared in @interface {}", iface)),
                );
            }
        }
        if !*is_write && !eff.reads.iter().any(|r| r == p) {
            if reported.insert((p.clone(), false)) {
                let msg = if eff.writes.iter().any(|w| w == p) {
                    format!("effect violation: `{}` is read, but the contract declares only writes({})", p, p)
                } else {
                    format!("effect violation: `{}` is read, but the contract does not declare reads({})", p, p)
                };
                diags.push(
                    Diag::err(Some("WVN003"), msg, *line).note(format!("contract declared in @interface {}", iface)),
                );
            }
        }
    }
}

fn collect_accesses(stmts: &[Stmt], out: &mut Vec<(String, bool, u32)>) {
    for s in stmts {
        match s {
            Stmt::Local { init, line, .. } => collect_expr(init, *line, out),
            Stmt::Assign { target, op, value, line } => {
                collect_expr(value, *line, out);
                if let LValue::Index { base, index } = target {
                    collect_expr(index, *line, out);
                    out.push((base.clone(), true, *line));
                    if *op == AssignOp::Add {
                        out.push((base.clone(), false, *line));
                    }
                }
            }
            Stmt::For { init, cond, body, line, .. } => {
                collect_expr(init, *line, out);
                collect_expr(cond, *line, out);
                collect_accesses(body, out);
            }
            Stmt::Return { value: Some(e), line } => collect_expr(e, *line, out),
            Stmt::Return { value: None, .. } => {}
        }
    }
}

fn collect_expr(e: &Expr, line: u32, out: &mut Vec<(String, bool, u32)>) {
    match e {
        Expr::Index { base, index } => {
            out.push((base.clone(), false, line));
            collect_expr(index, line, out);
        }
        Expr::Bin { lhs, rhs, .. } => {
            collect_expr(lhs, line, out);
            collect_expr(rhs, line, out);
        }
        _ => {}
    }
}

// ----------------------------------------------------------- vectorize check

#[derive(Clone, Copy, PartialEq)]
enum Sub {
    /// `iv + c` for constant c (c may be 0 or negative)
    Affine(i64),
    /// loop-invariant subscript
    Uniform,
}

struct Access {
    offset: Sub,
    write: bool,
    line: u32,
}

fn vectorize_check(
    decl: &MethodSig,
    def: &MethodDef,
    params: &HashMap<&str, &Param>,
    v: &Vectorize,
    diags: &mut Vec<Diag>,
) {
    if let Some(w) = v.width {
        if w == 0 || !w.is_power_of_two() {
            diags.push(Diag::err(None, format!("vectorize width must be a power of two, got {}", w), v.line));
        }
    }
    let loops: Vec<&Stmt> = def.body.iter().filter(|s| matches!(s, Stmt::For { .. })).collect();
    if loops.is_empty() {
        diags.push(Diag::err(Some("WVN010"), "vectorization required, but the kernel has no loop", v.line));
        return;
    }
    let outer_locals: Vec<(&str, &Type)> = def
        .body
        .iter()
        .filter_map(|s| match s {
            Stmt::Local { name, ty, .. } => Some((name.as_str(), ty)),
            _ => None,
        })
        .collect();

    for l in &loops {
        let Stmt::For { var, body, line, .. } = l else { unreachable!() };
        check_loop(var, body, *line, params, &outer_locals, decl.contracts.fp_reassoc, diags);
    }
}

fn check_loop(
    iv: &str,
    body: &[Stmt],
    loop_line: u32,
    params: &HashMap<&str, &Param>,
    outer_locals: &[(&str, &Type)],
    fp_reassoc: bool,
    diags: &mut Vec<Diag>,
) {
    let mut scan = LoopScan {
        iv,
        params,
        outer_locals,
        fp_reassoc,
        inner_locals: HashSet::new(),
        acc: HashMap::new(),
        diags,
    };
    scan.block(body);
    let acc = scan.acc;

    // memory dependences, per array
    for (p, accs) in &acc {
        let writes: Vec<&Access> = accs.iter().filter(|a| a.write).collect();
        if writes.is_empty() {
            continue;
        }
        if let Some(w) = writes.iter().find(|a| a.offset == Sub::Uniform) {
            diags.push(
                Diag::err(
                    Some("WVN014"),
                    format!(
                        "vectorization required, but `{}` is written at a loop-invariant subscript (every iteration writes the same location)",
                        p
                    ),
                    w.line,
                )
                .note("remove @vectorize(require) or restructure the recurrence"),
            );
            continue;
        }
        let wofs: Vec<(i64, u32)> = writes
            .iter()
            .filter_map(|a| match a.offset {
                Sub::Affine(c) => Some((c, a.line)),
                Sub::Uniform => None,
            })
            .collect();
        let mut reported: HashSet<(i64, i64)> = HashSet::new();
        // write/write conflicts
        for (i, (c1, l1)) in wofs.iter().enumerate() {
            for (c2, _) in wofs.iter().skip(i + 1) {
                if c1 != c2 && reported.insert((*c1.min(c2), *c1.max(c2))) {
                    diags.push(
                        Diag::err(
                            Some("WVN014"),
                            format!(
                                "vectorization required, but the loop carries an output dependence: `{}` is written at {}[{}] and {}[{}]",
                                p, p, off_str(iv, *c1), p, off_str(iv, *c2)
                            ),
                            *l1,
                        )
                        .note("remove @vectorize(require) or restructure the recurrence"),
                    );
                }
            }
        }
        // read/write conflicts
        let mut reported_rw: HashSet<(i64, i64)> = HashSet::new();
        for read in accs.iter().filter(|a| !a.write) {
            match read.offset {
                Sub::Uniform => {
                    diags.push(
                        Diag::err(
                            Some("WVN014"),
                            format!(
                                "vectorization required, but `{}` is read at a loop-invariant subscript while also being written in the loop",
                                p
                            ),
                            read.line,
                        )
                        .note("remove @vectorize(require) or restructure the recurrence"),
                    );
                }
                Sub::Affine(cr) => {
                    for (cw, wline) in &wofs {
                        if cr != *cw && reported_rw.insert((*cw, cr)) {
                            let msg = if cr == cw - 1 {
                                format!(
                                    "vectorization required, but the loop carries a dependence: {}[{}] reads {}[{}] written in the previous iteration",
                                    p, off_str(iv, *cw), p, off_str(iv, cr)
                                )
                            } else {
                                format!(
                                    "vectorization required, but the loop carries a dependence: `{}` is written at {}[{}] and read at {}[{}]",
                                    p, p, off_str(iv, *cw), p, off_str(iv, cr)
                                )
                            };
                            diags.push(
                                Diag::err(Some("WVN014"), msg, read.line.max(*wline))
                                    .note("remove @vectorize(require) or restructure the recurrence"),
                            );
                        }
                    }
                }
            }
        }
    }

    // aliasing: every pair of accessed pointer params must have a noalias
    // witness if any of them is written
    let written: Vec<&String> = acc
        .iter()
        .filter(|(_, accs)| accs.iter().any(|a| a.write))
        .map(|(p, _)| p)
        .collect();
    let mut reported_pairs: HashSet<(String, String)> = HashSet::new();
    for w in &written {
        for q in acc.keys() {
            if q == *w {
                continue;
            }
            let (Some(wp), Some(qp)) = (params.get(w.as_str()).copied(), params.get(q.as_str()).copied()) else {
                continue;
            };
            if !wp.noalias && !qp.noalias {
                let key = if *w < q { ((*w).clone(), q.clone()) } else { (q.clone(), (*w).clone()) };
                if reported_pairs.insert(key) {
                    diags.push(
                        Diag::err(
                            Some("WVN012"),
                            format!("vectorization required, but cannot prove `{}` and `{}` do not alias", w, q),
                            loop_line,
                        )
                        .note("add @noalias to the parameter declarations"),
                    );
                }
            }
        }
    }
}

struct LoopScan<'a> {
    iv: &'a str,
    params: &'a HashMap<&'a str, &'a Param>,
    outer_locals: &'a [(&'a str, &'a Type)],
    fp_reassoc: bool,
    inner_locals: HashSet<String>,
    acc: HashMap<String, Vec<Access>>,
    diags: &'a mut Vec<Diag>,
}

impl LoopScan<'_> {
    fn block(&mut self, stmts: &[Stmt]) {
        for s in stmts {
            match s {
                Stmt::Local { name, init, line, .. } => {
                    self.expr(init, *line);
                    self.inner_locals.insert(name.clone());
                }
                Stmt::Assign { target, op, value, line } => {
                    self.expr(value, *line);
                    match target {
                        LValue::Index { base, index } => {
                            self.expr(index, *line);
                            self.record(base, true, index, *line);
                            if *op == AssignOp::Add {
                                self.record(base, false, index, *line);
                            }
                        }
                        LValue::Var(n) => {
                            if n == self.iv {
                                self.diags.push(Diag::err(
                                    None,
                                    "the induction variable cannot be assigned in the loop body",
                                    *line,
                                ));
                            } else if self.inner_locals.contains(n) {
                                // fresh every iteration — fine
                            } else if let Some((_, ty)) = self.outer_locals.iter().find(|(ln, _)| ln == n) {
                                match op {
                                    AssignOp::Add => {
                                        if matches!(ty, Type::Float) && !self.fp_reassoc {
                                            self.diags.push(
                                                Diag::err(
                                                    Some("WVN015"),
                                                    format!(
                                                        "vectorization required, but the float reduction over `{}` reorders additions",
                                                        n
                                                    ),
                                                    *line,
                                                )
                                                .note("grant @fp(reassoc) to permit reassociation"),
                                            );
                                        }
                                    }
                                    AssignOp::Set => {
                                        self.diags.push(
                                            Diag::err(
                                                Some("WVN016"),
                                                format!(
                                                    "vectorization required, but `{}` is overwritten across iterations (scalar recurrence)",
                                                    n
                                                ),
                                                *line,
                                            )
                                            .note("remove @vectorize(require) or make the value per-iteration"),
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
                Stmt::For { line, .. } => {
                    self.diags.push(Diag::err(
                        Some("WVN011"),
                        "nested loops under @vectorize(require) are not supported in stage 0",
                        *line,
                    ));
                }
                Stmt::Return { line, .. } => {
                    self.diags.push(Diag::err(
                        None,
                        "return inside a @vectorize(require) loop is not vectorizable",
                        *line,
                    ));
                }
            }
        }
    }

    fn expr(&mut self, e: &Expr, line: u32) {
        match e {
            Expr::Index { base, index } => {
                self.record(base, false, index, line);
                self.expr(index, line);
            }
            Expr::Bin { lhs, rhs, .. } => {
                self.expr(lhs, line);
                self.expr(rhs, line);
            }
            _ => {}
        }
    }

    fn record(&mut self, base: &str, write: bool, index: &Expr, line: u32) {
        if !self.params.contains_key(base) {
            return;
        }
        match subscript_form(index, self.iv) {
            Some(offset) => {
                self.acc.entry(base.to_string()).or_default().push(Access { offset, write, line });
            }
            None => {
                self.diags.push(Diag::err(
                    Some("WVN010"),
                    format!(
                        "vectorization required, but subscript `{}[{}]` is not affine in `{}`",
                        base,
                        expr_str(index),
                        self.iv
                    ),
                    line,
                ));
            }
        }
    }
}

fn subscript_form(e: &Expr, iv: &str) -> Option<Sub> {
    match e {
        Expr::Var(n) if n == iv => Some(Sub::Affine(0)),
        Expr::Var(_) | Expr::Int(_) => Some(Sub::Uniform),
        Expr::Bin { op: BinOp::Add, lhs, rhs } => match (&**lhs, &**rhs) {
            (Expr::Var(n), Expr::Int(c)) if n == iv => Some(Sub::Affine(*c as i64)),
            (Expr::Int(c), Expr::Var(n)) if n == iv => Some(Sub::Affine(*c as i64)),
            _ => None,
        },
        Expr::Bin { op: BinOp::Sub, lhs, rhs } => match (&**lhs, &**rhs) {
            (Expr::Var(n), Expr::Int(c)) if n == iv => Some(Sub::Affine(-(*c as i64))),
            _ => None,
        },
        _ => None,
    }
}

fn off_str(iv: &str, c: i64) -> String {
    if c == 0 {
        iv.to_string()
    } else if c > 0 {
        format!("{} + {}", iv, c)
    } else {
        format!("{} - {}", iv, -c)
    }
}
