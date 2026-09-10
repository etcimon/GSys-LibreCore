// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Frozen registry SQL grammar. Anything else is a syntax error.

use crate::error::StoreError;
use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    CreateTable {
        if_not_exists: bool,
        name: String,
        cols: Vec<ColDef>,
    },
    DropTable {
        if_exists: bool,
        name: String,
    },
    Insert {
        table: String,
        cols: Option<Vec<String>>,
        rows: Vec<Vec<Value>>,
    },
    Update {
        table: String,
        sets: Vec<(String, Expr)>,
        where_clause: Option<Pred>,
    },
    Delete {
        table: String,
        where_clause: Option<Pred>,
    },
    Select {
        list: SelectList,
        table: String,
        join: Option<Join>,
        where_clause: Option<Pred>,
        order: Option<(String, bool)>,
        limit: Option<Value>,
        offset: Option<Value>,
    },
    Begin,
    Commit,
    Rollback,
    Listen {
        channel: String,
    },
    Unlisten {
        channel: Option<String>,
    },
    Notify {
        channel: String,
        payload: Option<String>,
    },
    Stat,
}

/// Inner join of two tables on one equality (`ON a.col = b.col`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Join {
    pub table: String,
    pub left: String,
    pub right: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColDef {
    pub name: String,
    pub ty: ColType,
    pub primary_key: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColType {
    Text,
    Integer,
    Real,
    Boolean,
    Json,
    Serial,
}

impl ColType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Text => "TEXT",
            Self::Integer => "INTEGER",
            Self::Real => "REAL",
            Self::Boolean => "BOOLEAN",
            Self::Json => "JSON",
            Self::Serial => "SERIAL",
        }
    }

    /// Postgres `dataTypeID` so a later Electric swap does not change D field poking.
    pub fn oid(self) -> u32 {
        match self {
            Self::Text => 25,
            Self::Integer | Self::Serial => 23,
            Self::Real => 701,
            Self::Boolean => 16,
            Self::Json => 114,
        }
    }

    pub fn parse(s: &str) -> Result<Self, StoreError> {
        Ok(match s.to_ascii_uppercase().as_str() {
            "TEXT" => Self::Text,
            "INTEGER" => Self::Integer,
            "REAL" => Self::Real,
            "BOOLEAN" => Self::Boolean,
            "JSON" => Self::Json,
            "SERIAL" => Self::Serial,
            _ => return Err(StoreError::syntax(format!("type {s}"))),
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SelectList {
    Star,
    Cols(Vec<String>),
    Agg(Agg),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Agg {
    CountAll,
    Count(String),
    Max(String),
    Min(String),
    Sum(String),
}

impl Agg {
    pub fn name(&self) -> &'static str {
        match self {
            Self::CountAll | Self::Count(_) => "count",
            Self::Max(_) => "max",
            Self::Min(_) => "min",
            Self::Sum(_) => "sum",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Real(f64),
    Str(String),
    Param(u32),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Value(Value),
    Ident(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Pred {
    And(Box<Pred>, Box<Pred>),
    Or(Box<Pred>, Box<Pred>),
    Not(Box<Pred>),
    Cmp(Expr, CmpOp, Expr),
    IsNull(Expr, bool),
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Int(i64),
    Real(f64),
    Str(String),
    Param(u32),
    Kw(&'static str),
    LParen,
    RParen,
    Comma,
    Star,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    Semi,
    Dot,
}

const KW: &[&str] = &[
    "CREATE", "TABLE", "IF", "NOT", "EXISTS", "DROP", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
    "DELETE", "FROM", "SELECT", "WHERE", "ORDER", "BY", "ASC", "DESC", "LIMIT", "OFFSET", "BEGIN",
    "COMMIT", "ROLLBACK", "AND", "OR", "IS", "NULL", "PRIMARY", "KEY", "TEXT", "INTEGER", "REAL",
    "BOOLEAN", "JSON", "SERIAL", "COUNT", "MAX", "MIN", "SUM", "TRUE", "FALSE", "INNER", "JOIN",
    "ON", "LISTEN", "UNLISTEN", "NOTIFY", "STAT",
];

fn keyword(s: &str) -> Option<&'static str> {
    let u = s.to_ascii_uppercase();
    KW.iter().copied().find(|k| *k == u)
}

pub fn parse_query(sql: &str) -> Result<Stmt, StoreError> {
    let mut p = Parser::lex(sql)?;
    let stmt = p.statement()?;
    p.optional_semi();
    p.expect_eof()?;
    Ok(stmt)
}

pub fn parse_exec(sql: &str) -> Result<Vec<Stmt>, StoreError> {
    let mut p = Parser::lex(sql)?;
    if p.saw_param {
        return Err(StoreError::syntax("exec does not take parameters"));
    }
    let mut out = Vec::new();
    loop {
        p.skip_semis();
        if p.done() {
            break;
        }
        out.push(p.statement()?);
        p.optional_semi();
    }
    if out.is_empty() {
        return Err(StoreError::syntax("empty exec"));
    }
    Ok(out)
}

struct Parser {
    toks: Vec<Tok>,
    i: usize,
    saw_param: bool,
}

impl Parser {
    fn lex(sql: &str) -> Result<Self, StoreError> {
        let mut toks = Vec::new();
        let b = sql.as_bytes();
        let mut i = 0;
        let mut saw_param = false;
        let mut params = BTreeSet::new();
        while i < b.len() {
            let c = b[i];
            if c.is_ascii_whitespace() {
                i += 1;
                continue;
            }
            if c == b'?' {
                return Err(StoreError::syntax("? is not a parameter; use $1"));
            }
            if c == b'-' && i + 1 < b.len() && b[i + 1].is_ascii_digit() {
                let (tok, n) = number(&b[i..])?;
                toks.push(tok);
                i += n;
                continue;
            }
            match c {
                b'(' => {
                    toks.push(Tok::LParen);
                    i += 1;
                }
                b')' => {
                    toks.push(Tok::RParen);
                    i += 1;
                }
                b',' => {
                    toks.push(Tok::Comma);
                    i += 1;
                }
                b'*' => {
                    toks.push(Tok::Star);
                    i += 1;
                }
                b';' => {
                    toks.push(Tok::Semi);
                    i += 1;
                }
                b'.' => {
                    toks.push(Tok::Dot);
                    i += 1;
                }
                b'=' => {
                    toks.push(Tok::Eq);
                    i += 1;
                }
                b'!' if i + 1 < b.len() && b[i + 1] == b'=' => {
                    toks.push(Tok::Ne);
                    i += 2;
                }
                b'<' if i + 1 < b.len() && b[i + 1] == b'>' => {
                    toks.push(Tok::Ne);
                    i += 2;
                }
                b'<' if i + 1 < b.len() && b[i + 1] == b'=' => {
                    toks.push(Tok::Le);
                    i += 2;
                }
                b'>' if i + 1 < b.len() && b[i + 1] == b'=' => {
                    toks.push(Tok::Ge);
                    i += 2;
                }
                b'<' => {
                    toks.push(Tok::Lt);
                    i += 1;
                }
                b'>' => {
                    toks.push(Tok::Gt);
                    i += 1;
                }
                b'\'' => {
                    let (s, n) = string_lit(&b[i..])?;
                    toks.push(Tok::Str(s));
                    i += n;
                }
                b'"' => {
                    let (s, n) = quoted_ident(&b[i..])?;
                    toks.push(Tok::Ident(s));
                    i += n;
                }
                b'$' => {
                    let (n, used) = param(&b[i..])?;
                    toks.push(Tok::Param(n));
                    params.insert(n);
                    saw_param = true;
                    i += used;
                }
                b'0'..=b'9' => {
                    let (tok, n) = number(&b[i..])?;
                    toks.push(tok);
                    i += n;
                }
                b'A'..=b'Z' | b'a'..=b'z' | b'_' => {
                    let start = i;
                    i += 1;
                    while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                        i += 1;
                    }
                    let raw = std::str::from_utf8(&b[start..i]).unwrap();
                    if let Some(k) = keyword(raw) {
                        toks.push(Tok::Kw(k));
                    } else {
                        toks.push(Tok::Ident(raw.to_string()));
                    }
                }
                other => {
                    return Err(StoreError::syntax(format!(
                        "unexpected {:?}",
                        other as char
                    )));
                }
            }
        }
        if !params.is_empty() {
            let max = *params.iter().max().unwrap();
            for n in 1..=max {
                if !params.contains(&n) {
                    return Err(StoreError::syntax("parameters must be dense from $1"));
                }
            }
        }
        Ok(Self {
            toks,
            i: 0,
            saw_param,
        })
    }

    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.i)
    }

    fn bump(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.i).cloned()?;
        self.i += 1;
        Some(t)
    }

    fn done(&self) -> bool {
        self.i >= self.toks.len()
    }

    fn skip_semis(&mut self) {
        while matches!(self.peek(), Some(Tok::Semi)) {
            self.i += 1;
        }
    }

    fn optional_semi(&mut self) {
        if matches!(self.peek(), Some(Tok::Semi)) {
            self.i += 1;
        }
    }

    fn expect_eof(&self) -> Result<(), StoreError> {
        if self.done() {
            Ok(())
        } else {
            Err(StoreError::syntax("trailing tokens"))
        }
    }

    fn eat_kw(&mut self, k: &'static str) -> Result<(), StoreError> {
        match self.bump() {
            Some(Tok::Kw(got)) if got == k => Ok(()),
            _ => Err(StoreError::syntax(format!("expected {k}"))),
        }
    }

    fn eat(&mut self, want: &Tok) -> Result<(), StoreError> {
        if self.peek() == Some(want) {
            self.i += 1;
            Ok(())
        } else {
            Err(StoreError::syntax("unexpected token"))
        }
    }

    fn ident(&mut self) -> Result<String, StoreError> {
        match self.bump() {
            Some(Tok::Ident(s)) => Ok(s),
            _ => Err(StoreError::syntax("expected identifier")),
        }
    }

    fn qident(&mut self) -> Result<String, StoreError> {
        let mut s = self.ident()?;
        if matches!(self.peek(), Some(Tok::Dot)) {
            self.bump();
            s.push('.');
            s.push_str(&self.ident()?);
        }
        Ok(s)
    }

    fn channel(&mut self) -> Result<String, StoreError> {
        match self.bump() {
            Some(Tok::Ident(s) | Tok::Str(s)) => Ok(s),
            Some(Tok::Kw(k)) => Ok(k.to_ascii_lowercase()),
            _ => Err(StoreError::syntax("expected channel")),
        }
    }

    fn statement(&mut self) -> Result<Stmt, StoreError> {
        match self.peek() {
            Some(Tok::Kw("CREATE")) => self.create_table(),
            Some(Tok::Kw("DROP")) => self.drop_table(),
            Some(Tok::Kw("INSERT")) => self.insert(),
            Some(Tok::Kw("UPDATE")) => self.update(),
            Some(Tok::Kw("DELETE")) => self.delete(),
            Some(Tok::Kw("SELECT")) => self.select(),
            Some(Tok::Kw("BEGIN")) => {
                self.bump();
                Ok(Stmt::Begin)
            }
            Some(Tok::Kw("COMMIT")) => {
                self.bump();
                Ok(Stmt::Commit)
            }
            Some(Tok::Kw("ROLLBACK")) => {
                self.bump();
                Ok(Stmt::Rollback)
            }
            Some(Tok::Kw("LISTEN")) => self.listen_stmt(),
            Some(Tok::Kw("UNLISTEN")) => self.unlisten_stmt(),
            Some(Tok::Kw("NOTIFY")) => self.notify_stmt(),
            Some(Tok::Kw("STAT")) => {
                self.bump();
                Ok(Stmt::Stat)
            }
            _ => Err(StoreError::syntax("unknown statement")),
        }
    }

    fn listen_stmt(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("LISTEN")?;
        Ok(Stmt::Listen {
            channel: self.channel()?,
        })
    }

    fn unlisten_stmt(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("UNLISTEN")?;
        let channel = match self.peek() {
            None | Some(Tok::Semi) => None,
            Some(Tok::Star) => {
                self.bump();
                Some("*".into())
            }
            _ => Some(self.channel()?),
        };
        Ok(Stmt::Unlisten { channel })
    }

    fn notify_stmt(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("NOTIFY")?;
        let channel = self.channel()?;
        let payload = if matches!(self.peek(), Some(Tok::Comma)) {
            self.bump();
            match self.bump() {
                Some(Tok::Str(s) | Tok::Ident(s)) => Some(s),
                _ => return Err(StoreError::syntax("expected notify payload")),
            }
        } else {
            None
        };
        Ok(Stmt::Notify { channel, payload })
    }

    fn create_table(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("CREATE")?;
        self.eat_kw("TABLE")?;
        let if_not_exists = if matches!(self.peek(), Some(Tok::Kw("IF"))) {
            self.bump();
            self.eat_kw("NOT")?;
            self.eat_kw("EXISTS")?;
            true
        } else {
            false
        };
        let name = self.ident()?;
        self.eat(&Tok::LParen)?;
        let mut cols = Vec::new();
        let mut pk = 0u32;
        loop {
            let cname = self.ident()?;
            let ty = match self.bump() {
                Some(Tok::Kw(k)) => ColType::parse(k)?,
                _ => return Err(StoreError::syntax("expected type")),
            };
            let mut primary_key = false;
            if matches!(self.peek(), Some(Tok::Kw("PRIMARY"))) {
                self.bump();
                self.eat_kw("KEY")?;
                primary_key = true;
                pk += 1;
            }
            cols.push(ColDef {
                name: cname,
                ty,
                primary_key,
            });
            match self.peek() {
                Some(Tok::Comma) => {
                    self.bump();
                }
                Some(Tok::RParen) => {
                    self.bump();
                    break;
                }
                _ => return Err(StoreError::syntax("expected , or )")),
            }
        }
        if pk > 1 {
            return Err(StoreError::syntax("at most one PRIMARY KEY"));
        }
        if cols.is_empty() {
            return Err(StoreError::syntax("empty column list"));
        }
        Ok(Stmt::CreateTable {
            if_not_exists,
            name,
            cols,
        })
    }

    fn drop_table(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("DROP")?;
        self.eat_kw("TABLE")?;
        let if_exists = if matches!(self.peek(), Some(Tok::Kw("IF"))) {
            self.bump();
            self.eat_kw("EXISTS")?;
            true
        } else {
            false
        };
        let name = self.ident()?;
        Ok(Stmt::DropTable { if_exists, name })
    }

    fn insert(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("INSERT")?;
        self.eat_kw("INTO")?;
        let table = self.ident()?;
        let cols = if matches!(self.peek(), Some(Tok::LParen)) {
            self.bump();
            let mut c = vec![self.ident()?];
            while matches!(self.peek(), Some(Tok::Comma)) {
                self.bump();
                c.push(self.ident()?);
            }
            self.eat(&Tok::RParen)?;
            Some(c)
        } else {
            None
        };
        self.eat_kw("VALUES")?;
        let mut rows = vec![self.value_row()?];
        while matches!(self.peek(), Some(Tok::Comma)) {
            self.bump();
            rows.push(self.value_row()?);
        }
        Ok(Stmt::Insert { table, cols, rows })
    }

    fn value_row(&mut self) -> Result<Vec<Value>, StoreError> {
        self.eat(&Tok::LParen)?;
        let mut row = vec![self.value()?];
        while matches!(self.peek(), Some(Tok::Comma)) {
            self.bump();
            row.push(self.value()?);
        }
        self.eat(&Tok::RParen)?;
        Ok(row)
    }

    fn value(&mut self) -> Result<Value, StoreError> {
        match self.bump() {
            Some(Tok::Kw("NULL")) => Ok(Value::Null),
            Some(Tok::Kw("TRUE")) => Ok(Value::Bool(true)),
            Some(Tok::Kw("FALSE")) => Ok(Value::Bool(false)),
            Some(Tok::Int(n)) => Ok(Value::Int(n)),
            Some(Tok::Real(n)) => Ok(Value::Real(n)),
            Some(Tok::Str(s)) => Ok(Value::Str(s)),
            Some(Tok::Param(n)) => Ok(Value::Param(n)),
            Some(Tok::Ident(_)) => Err(StoreError::syntax(
                "INSERT VALUES does not take a column ident",
            )),
            _ => Err(StoreError::syntax("expected value")),
        }
    }

    fn expr(&mut self) -> Result<Expr, StoreError> {
        match self.peek() {
            Some(Tok::Ident(_)) => {
                let s = self.ident()?;
                Ok(Expr::Ident(s))
            }
            _ => Ok(Expr::Value(self.value()?)),
        }
    }

    fn update(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("UPDATE")?;
        let table = self.ident()?;
        self.eat_kw("SET")?;
        let mut sets = vec![(self.ident()?, {
            self.eat(&Tok::Eq)?;
            self.expr()?
        })];
        while matches!(self.peek(), Some(Tok::Comma)) {
            self.bump();
            let name = self.ident()?;
            self.eat(&Tok::Eq)?;
            sets.push((name, self.expr()?));
        }
        let where_clause = self.optional_where()?;
        Ok(Stmt::Update {
            table,
            sets,
            where_clause,
        })
    }

    fn delete(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("DELETE")?;
        self.eat_kw("FROM")?;
        let table = self.ident()?;
        let where_clause = self.optional_where()?;
        Ok(Stmt::Delete {
            table,
            where_clause,
        })
    }

    fn select(&mut self) -> Result<Stmt, StoreError> {
        self.eat_kw("SELECT")?;
        let list = self.select_list()?;
        self.eat_kw("FROM")?;
        let table = self.ident()?;
        let join = if matches!(self.peek(), Some(Tok::Kw("INNER"))) {
            self.bump();
            self.eat_kw("JOIN")?;
            let right = self.ident()?;
            self.eat_kw("ON")?;
            let left_col = self.qident()?;
            self.eat(&Tok::Eq)?;
            let right_col = self.qident()?;
            Some(Join {
                table: right,
                left: left_col,
                right: right_col,
            })
        } else {
            None
        };
        if join.is_some() && matches!(list, SelectList::Agg(_)) {
            return Err(StoreError::syntax("join aggregate"));
        }
        let where_clause = self.optional_where()?;
        let order = if matches!(self.peek(), Some(Tok::Kw("ORDER"))) {
            self.bump();
            self.eat_kw("BY")?;
            let col = self.qident()?;
            let asc = match self.peek() {
                Some(Tok::Kw("DESC")) => {
                    self.bump();
                    false
                }
                Some(Tok::Kw("ASC")) => {
                    self.bump();
                    true
                }
                _ => true,
            };
            Some((col, asc))
        } else {
            None
        };
        let mut limit = None;
        let mut offset = None;
        if matches!(self.peek(), Some(Tok::Kw("LIMIT"))) {
            self.bump();
            limit = Some(self.int_or_param()?);
        }
        if matches!(self.peek(), Some(Tok::Kw("OFFSET"))) {
            self.bump();
            offset = Some(self.int_or_param()?);
        }
        Ok(Stmt::Select {
            list,
            table,
            join,
            where_clause,
            order,
            limit,
            offset,
        })
    }

    fn int_or_param(&mut self) -> Result<Value, StoreError> {
        match self.bump() {
            Some(Tok::Int(n)) => Ok(Value::Int(n)),
            Some(Tok::Param(n)) => Ok(Value::Param(n)),
            _ => Err(StoreError::syntax("expected int or $n")),
        }
    }

    fn select_list(&mut self) -> Result<SelectList, StoreError> {
        if matches!(self.peek(), Some(Tok::Star)) {
            self.bump();
            return Ok(SelectList::Star);
        }
        if let Some(Tok::Kw(k @ ("COUNT" | "MAX" | "MIN" | "SUM"))) = self.peek() {
            let k = *k;
            self.bump();
            self.eat(&Tok::LParen)?;
            let agg = match k {
                "COUNT" if matches!(self.peek(), Some(Tok::Star)) => {
                    self.bump();
                    Agg::CountAll
                }
                "COUNT" => Agg::Count(self.ident()?),
                "MAX" => Agg::Max(self.ident()?),
                "MIN" => Agg::Min(self.ident()?),
                "SUM" => Agg::Sum(self.ident()?),
                _ => unreachable!(),
            };
            self.eat(&Tok::RParen)?;
            if matches!(self.peek(), Some(Tok::Comma)) {
                return Err(StoreError::syntax("one aggregate only"));
            }
            return Ok(SelectList::Agg(agg));
        }
        let mut cols = vec![self.qident()?];
        while matches!(self.peek(), Some(Tok::Comma)) {
            self.bump();
            if let Some(Tok::Kw("COUNT" | "MAX" | "MIN" | "SUM")) = self.peek() {
                return Err(StoreError::syntax("cannot mix aggregate with columns"));
            }
            cols.push(self.qident()?);
        }
        Ok(SelectList::Cols(cols))
    }

    fn optional_where(&mut self) -> Result<Option<Pred>, StoreError> {
        if matches!(self.peek(), Some(Tok::Kw("WHERE"))) {
            self.bump();
            Ok(Some(self.pred()?))
        } else {
            Ok(None)
        }
    }

    fn pred(&mut self) -> Result<Pred, StoreError> {
        self.pred_or()
    }

    fn pred_or(&mut self) -> Result<Pred, StoreError> {
        let mut left = self.pred_and()?;
        while matches!(self.peek(), Some(Tok::Kw("OR"))) {
            self.bump();
            let right = self.pred_and()?;
            left = Pred::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn pred_and(&mut self) -> Result<Pred, StoreError> {
        let mut left = self.pred_not()?;
        while matches!(self.peek(), Some(Tok::Kw("AND"))) {
            self.bump();
            let right = self.pred_not()?;
            left = Pred::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn pred_not(&mut self) -> Result<Pred, StoreError> {
        if matches!(self.peek(), Some(Tok::Kw("NOT"))) {
            self.bump();
            Ok(Pred::Not(Box::new(self.pred_not()?)))
        } else {
            self.pred_atom()
        }
    }

    fn pred_atom(&mut self) -> Result<Pred, StoreError> {
        if matches!(self.peek(), Some(Tok::LParen)) {
            self.bump();
            let p = self.pred()?;
            self.eat(&Tok::RParen)?;
            return Ok(p);
        }
        let e = self.expr()?;
        if matches!(self.peek(), Some(Tok::Kw("IS"))) {
            self.bump();
            let not = if matches!(self.peek(), Some(Tok::Kw("NOT"))) {
                self.bump();
                true
            } else {
                false
            };
            self.eat_kw("NULL")?;
            return Ok(Pred::IsNull(e, not));
        }
        let op = match self.bump() {
            Some(Tok::Eq) => CmpOp::Eq,
            Some(Tok::Ne) => CmpOp::Ne,
            Some(Tok::Lt) => CmpOp::Lt,
            Some(Tok::Gt) => CmpOp::Gt,
            Some(Tok::Le) => CmpOp::Le,
            Some(Tok::Ge) => CmpOp::Ge,
            _ => return Err(StoreError::syntax("expected comparison")),
        };
        let r = self.expr()?;
        Ok(Pred::Cmp(e, op, r))
    }
}

fn number(b: &[u8]) -> Result<(Tok, usize), StoreError> {
    let mut i = 0;
    if b[0] == b'-' {
        i = 1;
    }
    let start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    if start == i {
        return Err(StoreError::syntax("bad number"));
    }
    let mut real = false;
    if i < b.len() && b[i] == b'.' {
        real = true;
        i += 1;
        let f = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == f {
            return Err(StoreError::syntax("bad real"));
        }
    }
    let s = std::str::from_utf8(&b[..i]).unwrap();
    if real {
        let n: f64 = s.parse().map_err(|_| StoreError::syntax("real"))?;
        Ok((Tok::Real(n), i))
    } else {
        let n: i64 = s.parse().map_err(|_| StoreError::syntax("int overflow"))?;
        Ok((Tok::Int(n), i))
    }
}

fn string_lit(b: &[u8]) -> Result<(String, usize), StoreError> {
    let mut i = 1;
    let mut out = String::new();
    while i < b.len() {
        if b[i] == b'\'' {
            if i + 1 < b.len() && b[i + 1] == b'\'' {
                out.push('\'');
                i += 2;
                continue;
            }
            return Ok((out, i + 1));
        }
        out.push(b[i] as char);
        i += 1;
    }
    Err(StoreError::syntax("unterminated string"))
}

fn quoted_ident(b: &[u8]) -> Result<(String, usize), StoreError> {
    let mut i = 1;
    let mut out = String::new();
    while i < b.len() {
        if b[i] == b'"' {
            if i + 1 < b.len() && b[i + 1] == b'"' {
                out.push('"');
                i += 2;
                continue;
            }
            if out.is_empty() {
                return Err(StoreError::syntax("empty ident"));
            }
            return Ok((out, i + 1));
        }
        out.push(b[i] as char);
        i += 1;
    }
    Err(StoreError::syntax("unterminated ident"))
}

fn param(b: &[u8]) -> Result<(u32, usize), StoreError> {
    if b.len() < 2 || b[1] < b'1' || b[1] > b'9' {
        return Err(StoreError::syntax("bad $n"));
    }
    let mut i = 1;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let n: u32 = std::str::from_utf8(&b[1..i])
        .unwrap()
        .parse()
        .map_err(|_| StoreError::syntax("bad $n"))?;
    Ok((n, i))
}
