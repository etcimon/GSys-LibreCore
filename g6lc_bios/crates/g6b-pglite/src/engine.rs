// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use crate::error::StoreError;
use crate::results::{Field, QueryResult};
use crate::sql::{Agg, CmpOp, ColDef, ColType, Expr, Join, Pred, SelectList, Stmt, Value};
use g6b_spec::{stringify_json, Json, StoreCfg};
use std::cmp::Ordering;
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct Table {
    pub cols: Vec<ColDef>,
    pub rows: Vec<Vec<Json>>,
    pub serial: i64,
}

impl Table {
    fn pk_index(&self) -> Option<usize> {
        self.cols.iter().position(|c| c.primary_key)
    }

    fn col_index(&self, name: &str) -> Result<usize, StoreError> {
        self.cols
            .iter()
            .position(|c| c.name == name)
            .ok_or_else(|| StoreError::exec(format!("no column {name}")))
    }
}

#[derive(Debug, Clone)]
pub struct Engine {
    pub tables: BTreeMap<String, Table>,
    pub tx: Option<BTreeMap<String, Table>>,
    cfg: StoreCfg,
}

impl Engine {
    pub fn new(cfg: StoreCfg) -> Self {
        Self {
            tables: BTreeMap::new(),
            tx: None,
            cfg,
        }
    }

    pub fn exec_stmt(&mut self, stmt: &Stmt, params: &[Json]) -> Result<QueryResult, StoreError> {
        match stmt {
            Stmt::Begin => {
                if self.tx.is_some() {
                    return Err(StoreError::Budget("tx"));
                }
                self.tx = Some(self.tables.clone());
                Ok(QueryResult::empty())
            }
            Stmt::Commit => {
                self.tx.take().ok_or_else(|| StoreError::exec("no tx"))?;
                Ok(QueryResult::empty())
            }
            Stmt::Rollback => {
                let snap = self.tx.take().ok_or_else(|| StoreError::exec("no tx"))?;
                self.tables = snap;
                Ok(QueryResult::empty())
            }
            Stmt::CreateTable {
                if_not_exists,
                name,
                cols,
            } => self.create_table(*if_not_exists, name, cols),
            Stmt::DropTable { if_exists, name } => self.drop_table(*if_exists, name),
            Stmt::Insert { table, cols, rows } => self.insert(table, cols.as_deref(), rows, params),
            Stmt::Update {
                table,
                sets,
                where_clause,
            } => self.update(table, sets, where_clause.as_ref(), params),
            Stmt::Delete {
                table,
                where_clause,
            } => self.delete(table, where_clause.as_ref(), params),
            Stmt::Select {
                list,
                table,
                join,
                where_clause,
                order,
                limit,
                offset,
            } => {
                if let Some(j) = join {
                    self.select_join(
                        list,
                        table,
                        j,
                        where_clause.as_ref(),
                        order.as_ref(),
                        limit.as_ref(),
                        offset.as_ref(),
                        params,
                    )
                } else {
                    self.select(
                        list,
                        table,
                        where_clause.as_ref(),
                        order.as_ref(),
                        limit.as_ref(),
                        offset.as_ref(),
                        params,
                    )
                }
            }
            Stmt::Listen { .. } | Stmt::Unlisten { .. } | Stmt::Notify { .. } | Stmt::Stat => {
                Err(StoreError::exec("catalog"))
            }
        }
    }

    fn create_table(
        &mut self,
        if_not_exists: bool,
        name: &str,
        cols: &[ColDef],
    ) -> Result<QueryResult, StoreError> {
        if self.tables.contains_key(name) {
            if if_not_exists {
                return Ok(QueryResult::empty());
            }
            return Err(StoreError::exec("table exists"));
        }
        if self.tables.len() as u32 >= self.cfg.max_tables {
            return Err(StoreError::Budget("tables"));
        }
        if cols.len() as u32 > self.cfg.max_columns {
            return Err(StoreError::Budget("columns"));
        }
        self.tables.insert(
            name.to_string(),
            Table {
                cols: cols.to_vec(),
                rows: Vec::new(),
                serial: 1,
            },
        );
        Ok(QueryResult::empty())
    }

    fn drop_table(&mut self, if_exists: bool, name: &str) -> Result<QueryResult, StoreError> {
        if self.tables.remove(name).is_none() && !if_exists {
            return Err(StoreError::exec("no table"));
        }
        Ok(QueryResult::empty())
    }

    fn table(&self, name: &str) -> Result<&Table, StoreError> {
        self.tables
            .get(name)
            .ok_or_else(|| StoreError::exec("no table"))
    }

    fn table_mut(&mut self, name: &str) -> Result<&mut Table, StoreError> {
        self.tables
            .get_mut(name)
            .ok_or_else(|| StoreError::exec("no table"))
    }

    fn insert(
        &mut self,
        table: &str,
        cols: Option<&[String]>,
        rows: &[Vec<Value>],
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        let names: Vec<String> = {
            let t = self.table(table)?;
            match cols {
                Some(c) => c.to_vec(),
                None => t.cols.iter().map(|c| c.name.clone()).collect(),
            }
        };
        let mut affected = 0u64;
        for row_vals in rows {
            if row_vals.len() != names.len() {
                return Err(StoreError::exec("column count"));
            }
            let mut cells = vec![Json::Null; self.table(table)?.cols.len()];
            for (name, val) in names.iter().zip(row_vals.iter()) {
                let t = self.table(table)?;
                let idx = t.col_index(name)?;
                cells[idx] = bind_value(val, params, t.cols[idx].ty)?;
            }
            self.fill_serials(table, &mut cells)?;
            self.check_pk(table, &cells, None)?;
            let max_rows = self.cfg.max_rows;
            let t = self.table_mut(table)?;
            if t.rows.len() as u32 >= max_rows {
                return Err(StoreError::Budget("rows"));
            }
            t.rows.push(cells);
            affected += 1;
        }
        Ok(QueryResult {
            rows: Vec::new(),
            fields: Vec::new(),
            affected_rows: affected,
        })
    }

    fn fill_serials(&mut self, table: &str, cells: &mut [Json]) -> Result<(), StoreError> {
        let t = self.table_mut(table)?;
        for (i, col) in t.cols.iter().enumerate() {
            if col.ty != ColType::Serial {
                continue;
            }
            if matches!(cells[i], Json::Null) {
                if t.serial == i64::MAX {
                    return Err(StoreError::exec("serial overflow"));
                }
                cells[i] = Json::Int(t.serial);
                t.serial += 1;
            }
        }
        Ok(())
    }

    fn check_pk(&self, table: &str, cells: &[Json], skip: Option<usize>) -> Result<(), StoreError> {
        let t = self.table(table)?;
        let Some(pk) = t.pk_index() else {
            return Ok(());
        };
        if matches!(cells[pk], Json::Null) {
            return Err(StoreError::exec("null pk"));
        }
        for (i, row) in t.rows.iter().enumerate() {
            if Some(i) == skip {
                continue;
            }
            if json_eq(&row[pk], &cells[pk]) {
                return Err(StoreError::exec("unique"));
            }
        }
        Ok(())
    }

    fn update(
        &mut self,
        table: &str,
        sets: &[(String, Expr)],
        pred: Option<&Pred>,
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        let n = self.table(table)?.rows.len();
        let mut affected = 0u64;
        for i in 0..n {
            if !self.row_matches(table, i, pred, params)? {
                continue;
            }
            let mut cells = self.table(table)?.rows[i].clone();
            for (name, expr) in sets {
                let t = self.table(table)?;
                let idx = t.col_index(name)?;
                cells[idx] = eval_expr(expr, &t.cols, &cells, params, t.cols[idx].ty)?;
            }
            self.check_pk(table, &cells, Some(i))?;
            self.table_mut(table)?.rows[i] = cells;
            affected += 1;
        }
        Ok(QueryResult {
            rows: Vec::new(),
            fields: Vec::new(),
            affected_rows: affected,
        })
    }

    fn delete(
        &mut self,
        table: &str,
        pred: Option<&Pred>,
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        let n = self.table(table)?.rows.len();
        let mut keep = Vec::new();
        let mut affected = 0u64;
        for i in 0..n {
            if self.row_matches(table, i, pred, params)? {
                affected += 1;
            } else {
                keep.push(self.table(table)?.rows[i].clone());
            }
        }
        self.table_mut(table)?.rows = keep;
        Ok(QueryResult {
            rows: Vec::new(),
            fields: Vec::new(),
            affected_rows: affected,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn select(
        &self,
        list: &SelectList,
        table: &str,
        pred: Option<&Pred>,
        order: Option<&(String, bool)>,
        limit: Option<&Value>,
        offset: Option<&Value>,
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        let t = self.table(table)?;
        let mut idxs: Vec<usize> = (0..t.rows.len())
            .filter(|&i| self.row_matches(table, i, pred, params).unwrap_or(false))
            .collect();
        // Re-check errors
        for i in 0..t.rows.len() {
            let _ = self.row_matches(table, i, pred, params)?;
        }
        if let Some((col, asc)) = order {
            let c = t.col_index(col)?;
            idxs.sort_by(|&a, &b| {
                let o = cmp_json(&t.rows[a][c], &t.rows[b][c]);
                if *asc {
                    o
                } else {
                    o.reverse()
                }
            });
        }
        let off = as_usize(offset, params)?;
        let lim = match limit {
            Some(v) => as_usize(Some(v), params)?,
            None => idxs.len(),
        };
        let slice: Vec<usize> = idxs.into_iter().skip(off).take(lim).collect();
        match list {
            SelectList::Star => project(t, &slice, None),
            SelectList::Cols(cols) => project(t, &slice, Some(cols)),
            SelectList::Agg(agg) => aggregate(t, &slice, agg),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn select_join(
        &self,
        list: &SelectList,
        left_name: &str,
        join: &Join,
        pred: Option<&Pred>,
        order: Option<&(String, bool)>,
        limit: Option<&Value>,
        offset: Option<&Value>,
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        let left = self.table(left_name)?;
        let right = self.table(&join.table)?;
        let (l_is_left, l_idx) =
            resolve_join_side(left_name, left, &join.table, right, &join.left)?;
        let (r_is_left, r_idx) =
            resolve_join_side(left_name, left, &join.table, right, &join.right)?;
        let (left_on, right_on) = match (l_is_left, r_is_left) {
            (true, false) => (l_idx, r_idx),
            (false, true) => (r_idx, l_idx),
            _ => return Err(StoreError::syntax("join on")),
        };
        let mut buckets: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (i, row) in right.rows.iter().enumerate() {
            let v = &row[right_on];
            if matches!(v, Json::Null) {
                continue;
            }
            buckets.entry(stringify_json(v)).or_default().push(i);
        }
        let (cols, map) = combined_schema(left_name, left, &join.table, right);
        let mut combined_rows: Vec<Vec<Json>> = Vec::new();
        for lrow in &left.rows {
            let v = &lrow[left_on];
            if matches!(v, Json::Null) {
                continue;
            }
            if let Some(idxs) = buckets.get(&stringify_json(v)) {
                for &ri in idxs {
                    let rrow = &right.rows[ri];
                    let mut row = Vec::with_capacity(map.len());
                    for &(is_left, idx) in &map {
                        row.push(if is_left {
                            lrow[idx].clone()
                        } else {
                            rrow[idx].clone()
                        });
                    }
                    combined_rows.push(row);
                }
            }
        }
        let virtual_table = Table {
            cols,
            rows: combined_rows,
            serial: 1,
        };
        let mut idxs: Vec<usize> = Vec::new();
        for i in 0..virtual_table.rows.len() {
            if match pred {
                None => true,
                Some(p) => eval_pred(p, &virtual_table.cols, &virtual_table.rows[i], params)?,
            } {
                idxs.push(i);
            }
        }
        if let Some((col, asc)) = order {
            let name = join_out_name(
                left_name,
                left,
                &join.table,
                right,
                &virtual_table.cols,
                col,
            )?;
            let c = virtual_table.col_index(&name)?;
            idxs.sort_by(|&a, &b| {
                let o = cmp_json(&virtual_table.rows[a][c], &virtual_table.rows[b][c]);
                if *asc {
                    o
                } else {
                    o.reverse()
                }
            });
        }
        let off = as_usize(offset, params)?;
        let lim = match limit {
            Some(v) => as_usize(Some(v), params)?,
            None => idxs.len(),
        };
        let slice: Vec<usize> = idxs.into_iter().skip(off).take(lim).collect();
        match list {
            SelectList::Star => project(&virtual_table, &slice, None),
            SelectList::Cols(cols) => {
                let names: Vec<String> = cols
                    .iter()
                    .map(|n| {
                        join_out_name(left_name, left, &join.table, right, &virtual_table.cols, n)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                project(&virtual_table, &slice, Some(&names))
            }
            SelectList::Agg(_) => Err(StoreError::syntax("join aggregate")),
        }
    }

    fn row_matches(
        &self,
        table: &str,
        i: usize,
        pred: Option<&Pred>,
        params: &[Json],
    ) -> Result<bool, StoreError> {
        let t = self.table(table)?;
        match pred {
            None => Ok(true),
            Some(p) => eval_pred(p, &t.cols, &t.rows[i], params),
        }
    }

    pub fn row_count(&self) -> u64 {
        self.tables.values().map(|t| t.rows.len() as u64).sum()
    }
}

fn strip_qident(name: &str) -> (&str, &str) {
    match name.split_once('.') {
        Some((t, c)) => (t, c),
        None => ("", name),
    }
}

fn resolve_join_side(
    lname: &str,
    left: &Table,
    rname: &str,
    right: &Table,
    ident: &str,
) -> Result<(bool, usize), StoreError> {
    let (prefix, col) = strip_qident(ident);
    let in_left = left.cols.iter().position(|c| c.name == col);
    let in_right = right.cols.iter().position(|c| c.name == col);
    if prefix == lname {
        return in_left
            .map(|i| (true, i))
            .ok_or_else(|| StoreError::exec(format!("no column {ident}")));
    }
    if prefix == rname {
        return in_right
            .map(|i| (false, i))
            .ok_or_else(|| StoreError::exec(format!("no column {ident}")));
    }
    if !prefix.is_empty() {
        return Err(StoreError::exec(format!("no column {ident}")));
    }
    match (in_left, in_right) {
        (Some(i), None) => Ok((true, i)),
        (None, Some(i)) => Ok((false, i)),
        (Some(_), Some(_)) => Err(StoreError::exec(format!("ambiguous {ident}"))),
        (None, None) => Err(StoreError::exec(format!("no column {ident}"))),
    }
}

fn combined_schema(
    _lname: &str,
    left: &Table,
    rname: &str,
    right: &Table,
) -> (Vec<ColDef>, Vec<(bool, usize)>) {
    let mut cols = Vec::new();
    let mut map = Vec::new();
    let mut used: Vec<String> = Vec::new();
    for (i, c) in left.cols.iter().enumerate() {
        cols.push(c.clone());
        map.push((true, i));
        used.push(c.name.clone());
    }
    for (i, c) in right.cols.iter().enumerate() {
        let name = if used.iter().any(|n| n == &c.name) {
            format!("{rname}_{}", c.name)
        } else {
            c.name.clone()
        };
        used.push(name.clone());
        let mut col = c.clone();
        col.name = name;
        cols.push(col);
        map.push((false, i));
    }
    (cols, map)
}

fn join_out_name(
    lname: &str,
    left: &Table,
    rname: &str,
    right: &Table,
    combined: &[ColDef],
    ident: &str,
) -> Result<String, StoreError> {
    let (is_left, idx) = resolve_join_side(lname, left, rname, right, ident)?;
    if is_left {
        return Ok(left.cols[idx].name.clone());
    }
    let orig = &right.cols[idx].name;
    let renamed = format!("{rname}_{orig}");
    if combined.iter().any(|c| c.name == renamed) {
        Ok(renamed)
    } else if combined.iter().any(|c| c.name == *orig) {
        Ok(orig.clone())
    } else {
        Err(StoreError::exec(format!("no column {ident}")))
    }
}

fn project(t: &Table, idxs: &[usize], cols: Option<&[String]>) -> Result<QueryResult, StoreError> {
    let names: Vec<String> = match cols {
        Some(c) => c.to_vec(),
        None => t.cols.iter().map(|c| c.name.clone()).collect(),
    };
    let fields: Vec<Field> = names
        .iter()
        .map(|n| {
            let oid = t
                .cols
                .iter()
                .find(|c| c.name == *n)
                .map(|c| c.ty.oid())
                .unwrap_or(25);
            Field {
                name: n.clone(),
                data_type_id: oid,
            }
        })
        .collect();
    let mut rows = Vec::new();
    for &i in idxs {
        let mut m = BTreeMap::new();
        for n in &names {
            let idx = t.col_index(n)?;
            m.insert(n.clone(), t.rows[i][idx].clone());
        }
        rows.push(m);
    }
    Ok(QueryResult {
        rows,
        fields,
        affected_rows: 0,
    })
}

fn aggregate(t: &Table, idxs: &[usize], agg: &Agg) -> Result<QueryResult, StoreError> {
    let json = match agg {
        Agg::CountAll => Json::Int(idxs.len() as i64),
        Agg::Count(col) => {
            let i = t.col_index(col)?;
            Json::Int(
                idxs.iter()
                    .filter(|&&r| !matches!(t.rows[r][i], Json::Null))
                    .count() as i64,
            )
        }
        Agg::Max(col) | Agg::Min(col) => {
            let i = t.col_index(col)?;
            let mut best: Option<&Json> = None;
            let want_max = matches!(agg, Agg::Max(_));
            for &r in idxs {
                let v = &t.rows[r][i];
                if matches!(v, Json::Null) {
                    continue;
                }
                best = Some(match best {
                    None => v,
                    Some(b) => {
                        let o = cmp_json(v, b);
                        if (want_max && o == Ordering::Greater)
                            || (!want_max && o == Ordering::Less)
                        {
                            v
                        } else {
                            b
                        }
                    }
                });
            }
            best.cloned().unwrap_or(Json::Null)
        }
        Agg::Sum(col) => {
            let i = t.col_index(col)?;
            let mut acc_i: Option<i64> = Some(0);
            let mut acc_f = 0.0;
            let mut any = false;
            for &r in idxs {
                match &t.rows[r][i] {
                    Json::Null => {}
                    Json::Int(n) => {
                        any = true;
                        if let Some(a) = acc_i {
                            acc_i = a.checked_add(*n);
                        }
                        acc_f += *n as f64;
                    }
                    Json::F64(n) => {
                        any = true;
                        acc_i = None;
                        acc_f += *n;
                    }
                    _ => return Err(StoreError::exec("sum type")),
                }
            }
            if !any {
                Json::Null
            } else if let Some(a) = acc_i {
                Json::Int(a)
            } else {
                Json::F64(acc_f)
            }
        }
    };
    let mut row = BTreeMap::new();
    row.insert(agg.name().into(), json);
    Ok(QueryResult {
        rows: vec![row],
        fields: vec![Field {
            name: agg.name().into(),
            data_type_id: 23,
        }],
        affected_rows: 0,
    })
}

fn bind_value(v: &Value, params: &[Json], ty: ColType) -> Result<Json, StoreError> {
    let raw = match v {
        Value::Null => Json::Null,
        Value::Bool(b) => Json::Bool(*b),
        Value::Int(n) => Json::Int(*n),
        Value::Real(n) => Json::F64(*n),
        Value::Str(s) => Json::Str(s.clone()),
        Value::Param(n) => {
            let i = (*n as usize)
                .checked_sub(1)
                .ok_or(StoreError::exec("bind"))?;
            params.get(i).cloned().ok_or(StoreError::exec("bind"))?
        }
    };
    coerce(raw, ty)
}

fn eval_expr(
    e: &Expr,
    cols: &[ColDef],
    row: &[Json],
    params: &[Json],
    ty: ColType,
) -> Result<Json, StoreError> {
    match e {
        Expr::Value(v) => bind_value(v, params, ty),
        Expr::Ident(name) => {
            let i = cols
                .iter()
                .position(|c| c.name == *name)
                .ok_or_else(|| StoreError::exec(format!("no column {name}")))?;
            Ok(row[i].clone())
        }
    }
}

fn eval_pred(p: &Pred, cols: &[ColDef], row: &[Json], params: &[Json]) -> Result<bool, StoreError> {
    match p {
        Pred::And(a, b) => Ok(eval_pred(a, cols, row, params)? && eval_pred(b, cols, row, params)?),
        Pred::Or(a, b) => Ok(eval_pred(a, cols, row, params)? || eval_pred(b, cols, row, params)?),
        Pred::Not(a) => Ok(!eval_pred(a, cols, row, params)?),
        Pred::IsNull(e, not) => {
            let v = eval_untyped(e, cols, row, params)?;
            let is_null = matches!(v, Json::Null);
            Ok(if *not { !is_null } else { is_null })
        }
        Pred::Cmp(l, op, r) => {
            let a = eval_untyped(l, cols, row, params)?;
            let b = eval_untyped(r, cols, row, params)?;
            if matches!(a, Json::Null) || matches!(b, Json::Null) {
                return Ok(false);
            }
            let o = cmp_json(&a, &b);
            Ok(match op {
                CmpOp::Eq => o == Ordering::Equal,
                CmpOp::Ne => o != Ordering::Equal,
                CmpOp::Lt => o == Ordering::Less,
                CmpOp::Gt => o == Ordering::Greater,
                CmpOp::Le => o != Ordering::Greater,
                CmpOp::Ge => o != Ordering::Less,
            })
        }
    }
}

fn eval_untyped(
    e: &Expr,
    cols: &[ColDef],
    row: &[Json],
    params: &[Json],
) -> Result<Json, StoreError> {
    match e {
        Expr::Ident(name) => {
            let i = cols
                .iter()
                .position(|c| c.name == *name)
                .ok_or_else(|| StoreError::exec(format!("no column {name}")))?;
            Ok(row[i].clone())
        }
        Expr::Value(Value::Param(n)) => {
            let i = (*n as usize)
                .checked_sub(1)
                .ok_or(StoreError::exec("bind"))?;
            params.get(i).cloned().ok_or(StoreError::exec("bind"))
        }
        Expr::Value(Value::Null) => Ok(Json::Null),
        Expr::Value(Value::Bool(b)) => Ok(Json::Bool(*b)),
        Expr::Value(Value::Int(n)) => Ok(Json::Int(*n)),
        Expr::Value(Value::Real(n)) => Ok(Json::F64(*n)),
        Expr::Value(Value::Str(s)) => Ok(Json::Str(s.clone())),
    }
}

fn coerce(v: Json, ty: ColType) -> Result<Json, StoreError> {
    if matches!(v, Json::Null) {
        return Ok(Json::Null);
    }
    match ty {
        ColType::Text => Ok(Json::Str(match v {
            Json::Str(s) => s,
            other => stringify_json(&other),
        })),
        ColType::Integer | ColType::Serial => match v {
            Json::Int(n) => Ok(Json::Int(n)),
            Json::Bool(b) => Ok(Json::Int(i64::from(b))),
            Json::F64(n) if n.fract() == 0.0 => Ok(Json::Int(n as i64)),
            Json::Str(s) => s
                .parse::<i64>()
                .map(Json::Int)
                .map_err(|_| StoreError::exec("integer")),
            _ => Err(StoreError::exec("integer")),
        },
        ColType::Real => match v {
            Json::F64(n) => Ok(Json::F64(n)),
            Json::Int(n) => Ok(Json::F64(n as f64)),
            Json::Str(s) => s
                .parse::<f64>()
                .map(Json::F64)
                .map_err(|_| StoreError::exec("real")),
            _ => Err(StoreError::exec("real")),
        },
        ColType::Boolean => match v {
            Json::Bool(b) => Ok(Json::Bool(b)),
            Json::Int(0) => Ok(Json::Bool(false)),
            Json::Int(1) => Ok(Json::Bool(true)),
            _ => Err(StoreError::exec("boolean")),
        },
        ColType::Json => Ok(v),
    }
}

fn json_eq(a: &Json, b: &Json) -> bool {
    cmp_json(a, b) == Ordering::Equal
}

fn cmp_json(a: &Json, b: &Json) -> Ordering {
    match (a, b) {
        (Json::Null, Json::Null) => Ordering::Equal,
        (Json::Null, _) => Ordering::Less,
        (_, Json::Null) => Ordering::Greater,
        (Json::Bool(x), Json::Bool(y)) => x.cmp(y),
        (Json::Int(x), Json::Int(y)) => x.cmp(y),
        (Json::Int(x), Json::F64(y)) => (*x as f64).partial_cmp(y).unwrap_or(Ordering::Equal),
        (Json::F64(x), Json::Int(y)) => x.partial_cmp(&(*y as f64)).unwrap_or(Ordering::Equal),
        (Json::F64(x), Json::F64(y)) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
        (Json::Str(x), Json::Str(y)) => x.cmp(y),
        _ => stringify_json(a).cmp(&stringify_json(b)),
    }
}

fn as_usize(v: Option<&Value>, params: &[Json]) -> Result<usize, StoreError> {
    let Some(v) = v else {
        return Ok(0);
    };
    let n = match v {
        Value::Int(n) => *n,
        Value::Param(p) => match params.get((*p as usize).saturating_sub(1)) {
            Some(Json::Int(n)) => *n,
            _ => return Err(StoreError::exec("bind")),
        },
        _ => return Err(StoreError::syntax("limit/offset")),
    };
    if n < 0 {
        return Err(StoreError::exec("limit/offset"));
    }
    Ok(n as usize)
}
