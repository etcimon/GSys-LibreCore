// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Fast HolyC subset used to initialize rust-generated ZealOS.
//!
//! Parses generated `KMain.ZC` / `Adam.ZC` / `PostBoot.ZC` and interprets them
//! on the host. RISC-V ISel (`isel`) is a Target wrapper around `g6b-asm` IR
//! (purpose-tagged nodes, not string `.S`). RVV only when the BoardSpec says so.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_http::Router;

pub mod isel;

/// Result of one REPL line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplResult {
    /// Function/Print output (may be empty).
    Output(String),
    /// Client asked to hang up.
    Exit,
}

/// Parsed HolyC program plus post-boot flags.
#[derive(Debug, Clone)]
pub struct Program {
    fns: BTreeMap<String, Function>,
    consts: BTreeMap<String, i64>,
    /// Section names that become write-disabled after [`Program::linux_handoff`].
    pub immutable: Vec<String>,
    /// Set by the `LinuxHandoff` builtin.
    pub linux_booted: bool,
    /// Last power verb (`reboot` / `shutdown` / `wakeup`).
    pub last_power: Option<String>,
    /// Print `NET-DELEGATE` on handoff (adapter released to Linux).
    pub net_delegates: bool,
    /// Print `LOOPBACK-MBOX` on handoff (sideband stays).
    pub loopback: bool,
    /// Print `SSH-HOLYC` when the ZealOS CLI KVM face is live.
    pub ssh_holyc: bool,
    /// Shared kernel HTTP router (HolyC ≡ JS).
    pub router: Router,
}

#[derive(Debug, Clone)]
struct Function {
    return_type: String,
    // Retain declarations even when the legacy boot interpreter ignores them.
    parameters: String,
    body: Vec<Stmt>,
}

#[derive(Debug, Clone)]
enum Stmt {
    Call { name: String, args: Vec<Expr> },
}

#[derive(Debug, Clone)]
enum Expr {
    Int(i64),
    UInt(u64),
    Str(String),
    Var(String),
}

/// Maximum instructions over a task's entire lifetime, including returns.
pub const HANDLER_MAX_STEPS: usize = 65_536;
/// Maximum number of simultaneously active handler frames.
pub const HANDLER_MAX_DEPTH: usize = 64;
/// Maximum UTF-8 bytes in a task's output or exception result.
pub const HANDLER_MAX_OUTPUT_BYTES: usize = 65_536;
/// Maximum reachable preparation units (functions, statements and operands).
pub const HANDLER_MAX_CODE_UNITS: usize = 16_384;
/// Maximum aggregate reachable declaration, identifier and literal bytes.
pub const HANDLER_MAX_CODE_BYTES: usize = 262_144;
/// Maximum source bytes accepted by [`parse_thread_request`].
pub const THREAD_REQUEST_MAX_BYTES: usize = 4_096;
const HANDLER_MAX_ARGS: usize = 32;
// Generated boot/menu output has a larger allowance than an isolated task.
const LEGACY_MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

/// Validated request only: scheduling and task IDs belong to the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadRequest {
    pub handler: String,
    pub argument: u64,
}

/// Parse exactly `ThreadCreate("Handler", 123)` with an optional semicolon.
/// The argument is an unsigned decimal literal; expressions, signs, comments,
/// extra commands and invalid handler identifiers are rejected. No task is run.
pub fn parse_thread_request(src: &str) -> Result<ThreadRequest, String> {
    if src.len() > THREAD_REQUEST_MAX_BYTES {
        return Err("ThreadCreate request size limit exceeded".into());
    }
    let mut rest = src.trim();
    if take_ident(&mut rest).as_deref() != Some("ThreadCreate") {
        return Err("expected ThreadCreate".into());
    }
    rest = rest
        .trim_start()
        .strip_prefix('(')
        .ok_or("expected (")?
        .trim_start();
    let handler = parse_string(&mut rest)?;
    let mut ident = handler.as_str();
    if take_ident(&mut ident).as_deref() != Some(handler.as_str()) || !ident.is_empty() {
        return Err("invalid handler identifier".into());
    }
    rest = rest
        .trim_start()
        .strip_prefix(',')
        .ok_or("expected ,")?
        .trim_start();
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return Err("expected unsigned decimal argument".into());
    }
    let argument = rest[..digits]
        .parse::<u64>()
        .map_err(|_| "thread argument out of range")?;
    rest = rest[digits..]
        .trim_start()
        .strip_prefix(')')
        .ok_or("expected )")?
        .trim_start();
    if let Some(tail) = rest.strip_prefix(';') {
        rest = tail.trim_start();
    }
    if !rest.is_empty() {
        return Err("trailing ThreadCreate input".into());
    }
    Ok(ThreadRequest { handler, argument })
}

/// A cooperative boundary or the task's terminal result (not a scheduler ID).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandlerPoll {
    Yielded,
    Finished(Result<String, String>),
}

/// Owned, isolated, bounded host interpreter state, not compiled guest code.
/// It holds neither a Program/router borrow nor scheduler/DOM/kernel ownership.
#[derive(Debug)]
pub struct HandlerTask {
    functions: Vec<TaskFunction>,
    stack: Vec<TaskFrame>,
    steps: usize,
    output: String,
    result: Option<Result<String, String>>,
}

#[derive(Debug, Clone, Copy)]
enum ParameterType {
    U64,
    I64,
}

#[derive(Debug, Clone, Copy)]
enum Number {
    Unsigned(u64),
    Signed(i64),
}

impl Number {
    fn cast(self, ty: ParameterType) -> Self {
        // HolyC integer conversion preserves the opaque 64-bit pattern.
        let bits = match self {
            Self::Unsigned(n) => n,
            Self::Signed(n) => n as u64,
        };
        match ty {
            ParameterType::U64 => Self::Unsigned(bits),
            ParameterType::I64 => Self::Signed(bits as i64),
        }
    }

    fn text(self) -> String {
        match self {
            Self::Unsigned(n) => n.to_string(),
            Self::Signed(n) => n.to_string(),
        }
    }
}

#[derive(Debug)]
enum TaskExpr {
    Number(Number),
    Text(String),
    Argument,
}

impl TaskExpr {
    fn number(&self, argument: Option<Number>) -> Number {
        match self {
            Self::Number(n) => *n,
            Self::Argument => argument.expect("prepared argument binding"),
            Self::Text(_) => unreachable!("prepared numeric operand"),
        }
    }

    fn text(&self, argument: Option<Number>) -> std::borrow::Cow<'_, str> {
        match self {
            Self::Text(s) => std::borrow::Cow::Borrowed(s),
            _ => std::borrow::Cow::Owned(self.number(argument).text()),
        }
    }
}

#[derive(Debug)]
enum TaskStmt {
    Print(Vec<TaskExpr>),
    Yield,
    Throw(TaskExpr),
    Sha256(TaskExpr),
    Call {
        target: usize,
        argument: Option<TaskExpr>,
    },
}

#[derive(Debug)]
struct TaskFunction {
    parameter: Option<ParameterType>,
    body: Vec<TaskStmt>,
}

#[derive(Debug)]
struct TaskFrame {
    function: usize,
    pc: usize,
    argument: Option<Number>,
}

enum TaskStep {
    Continue,
    Yield,
    Done,
}

impl HandlerTask {
    /// Execute at most `max_steps` statements/returns, stopping at `Yield()`.
    /// A zero budget makes no progress. Exhausting this poll's budget yields;
    /// exhausting the lifetime budget fails. Explicit yields do not reset it.
    /// Output is accumulated until success; a catchless `Throw(value)` instead
    /// returns `Err("HolyC exception: ...")` and discards prior output.
    /// Terminal polls are idempotent and return the same bounded result.
    pub fn poll(&mut self, max_steps: usize) -> HandlerPoll {
        if let Some(result) = &self.result {
            return HandlerPoll::Finished(result.clone());
        }
        for _ in 0..max_steps {
            if self.steps == HANDLER_MAX_STEPS {
                return self.finish(Err("HolyC instruction limit exceeded".into()));
            }
            self.steps += 1;
            match self.step() {
                Ok(TaskStep::Continue) => {}
                Ok(TaskStep::Yield) => return HandlerPoll::Yielded,
                Ok(TaskStep::Done) => {
                    let output = std::mem::take(&mut self.output);
                    return self.finish(Ok(output));
                }
                Err(error) => return self.finish(Err(error)),
            }
        }
        HandlerPoll::Yielded
    }

    fn finish(&mut self, result: Result<String, String>) -> HandlerPoll {
        self.stack.clear();
        self.output.clear();
        self.result = Some(result.clone());
        HandlerPoll::Finished(result)
    }

    fn step(&mut self) -> Result<TaskStep, String> {
        let frame = self.stack.last_mut().expect("unfinished task frame");
        let Some(stmt) = self.functions[frame.function].body.get(frame.pc) else {
            self.stack.pop();
            return Ok(if self.stack.is_empty() {
                TaskStep::Done
            } else {
                TaskStep::Continue
            });
        };
        frame.pc += 1;
        let argument = frame.argument;
        match stmt {
            TaskStmt::Print(args) => {
                for arg in args {
                    append_bounded(
                        &mut self.output,
                        &arg.text(argument),
                        HANDLER_MAX_OUTPUT_BYTES,
                    )?;
                }
            }
            TaskStmt::Yield => return Ok(TaskStep::Yield),
            TaskStmt::Throw(arg) => {
                let mut error = String::from("HolyC exception: ");
                append_bounded(&mut error, &arg.text(argument), HANDLER_MAX_OUTPUT_BYTES)?;
                return Err(error);
            }
            TaskStmt::Sha256(arg) => {
                let text = arg.text(argument);
                let digest = g6b_tls::sha256_hex(text.as_bytes());
                append_bounded(&mut self.output, &digest, HANDLER_MAX_OUTPUT_BYTES)?;
            }
            TaskStmt::Call {
                target,
                argument: arg,
            } => {
                if self.stack.len() == HANDLER_MAX_DEPTH {
                    return Err("HolyC call depth limit exceeded".into());
                }
                let value = self.functions[*target].parameter.map(|ty| {
                    arg.as_ref()
                        .expect("prepared call arity")
                        .number(argument)
                        .cast(ty)
                });
                self.stack.push(TaskFrame {
                    function: *target,
                    pc: 0,
                    argument: value,
                });
            }
        }
        Ok(TaskStep::Continue)
    }
}

fn append_bounded(out: &mut String, text: &str, limit: usize) -> Result<(), String> {
    if text.len() > limit.saturating_sub(out.len()) {
        return Err("HolyC output limit exceeded".into());
    }
    out.push_str(text);
    Ok(())
}

#[derive(Default)]
struct PreparationBudget {
    units: usize,
    bytes: usize,
}

impl PreparationBudget {
    fn charge(&mut self, units: usize, bytes: usize) -> Result<(), String> {
        if units > HANDLER_MAX_CODE_UNITS.saturating_sub(self.units)
            || bytes > HANDLER_MAX_CODE_BYTES.saturating_sub(self.bytes)
        {
            return Err("HolyC handler preparation limit exceeded".into());
        }
        self.units += units;
        self.bytes += bytes;
        Ok(())
    }
}

fn handler_parameter(function: &Function) -> Result<Option<(ParameterType, String)>, String> {
    if function.return_type != "U0" {
        return Err("handler must return U0".into());
    }
    let mut rest = function.parameters.trim();
    if rest.is_empty() {
        return Ok(None);
    }
    let kind = match take_ident(&mut rest).as_deref() {
        Some("U64") => ParameterType::U64,
        Some("I64") => ParameterType::I64,
        _ => return Err("handler parameter must be U64 or I64".into()),
    };
    let name = take_ident(&mut rest).ok_or("expected handler parameter name")?;
    if !rest.trim().is_empty() {
        return Err("handler accepts only one scalar parameter".into());
    }
    Ok(Some((kind, name)))
}

fn prepare_expr(
    expr: &Expr,
    parameter: Option<&str>,
    consts: &BTreeMap<String, i64>,
    budget: &mut PreparationBudget,
) -> Result<TaskExpr, String> {
    budget.charge(
        1,
        match expr {
            Expr::Str(s) | Expr::Var(s) => s.len(),
            _ => 0,
        },
    )?;
    Ok(match expr {
        Expr::Int(n) => TaskExpr::Number(Number::Signed(*n)),
        Expr::UInt(n) => TaskExpr::Number(Number::Unsigned(*n)),
        Expr::Str(s) => {
            if s.len() > HANDLER_MAX_OUTPUT_BYTES {
                return Err("HolyC handler literal size limit exceeded".into());
            }
            TaskExpr::Text(s.clone())
        }
        Expr::Var(name) if parameter == Some(name.as_str()) => TaskExpr::Argument,
        Expr::Var(name) => TaskExpr::Number(Number::Signed(
            *consts.get(name).ok_or("unknown handler variable")?,
        )),
    })
}

// These names have precedence over user declarations in the legacy interpreter.
// Never let a registered declaration disguise a kernel/global builtin as a task.
fn legacy_builtin_name(name: &str) -> bool {
    matches!(
        name,
        "Print"
            | "Reboot"
            | "Shutdown"
            | "Wakeup"
            | "LinuxHandoff"
            | "ViewSection"
            | "WriteSection"
            | "TimerInit"
            | "TlsHandshake"
            | "TlsServerHello"
            | "HttpsServe"
            | "FileServe"
            | "HttpFile"
            | "HttpsGet"
            | "TlsClientHello"
            | "CertParse"
            | "RsaVerify"
            | "EcdsaVerify"
            | "NetOpenPort"
            | "RegisterEndpoint"
            | "HttpHandle"
            | "KernelGet"
            | "SettingsExport"
            | "SettingsImport"
            | "FlashImage"
            | "BiosUpdate"
            | "UsbKey"
            | "UsbLs"
            | "UsbFlash"
            | "Menu"
            | "MenuCpu"
            | "MenuUncore"
            | "MenuMemory"
            | "MenuBoot"
    )
}

impl Default for Program {
    fn default() -> Self {
        Self {
            fns: BTreeMap::new(),
            consts: BTreeMap::new(),
            immutable: vec!["config".into(), "keys".into(), "boot-policy".into()],
            linux_booted: false,
            last_power: None,
            net_delegates: false,
            loopback: false,
            ssh_holyc: false,
            router: Router::default(),
        }
    }
}

impl Program {
    /// Parse a HolyC subset document.
    pub fn parse(src: &str) -> Result<Self, String> {
        let mut p = Program::default();
        let body = strip_comments(src)?;
        let mut rest = body.as_str();
        while !rest.trim().is_empty() {
            skip_ws(&mut rest);
            if rest.is_empty() {
                break;
            }
            if rest.starts_with("#include") {
                skip_line(&mut rest);
                continue;
            }
            if rest.starts_with("#define") {
                parse_define(&mut p, &mut rest)?;
                continue;
            }
            parse_fn(&mut p, &mut rest)?;
        }
        Ok(p)
    }

    /// Prepare a registered `U0 Handler()` or `U0 Handler(U64 arg)` task.
    /// `I64` is also accepted: the opaque argument's 64 bits are interpreted as
    /// two's-complement signed, and nested scalar calls use the same bit-preserving
    /// conversion. A no-argument entry ignores the supplied opaque argument.
    ///
    /// All reachable calls are validated before any execution, including code
    /// after `Throw`. Only registered U0 scalar functions, `Print(...)`, `Yield()`,
    /// `Throw(value)` and `Sha256(value)` are allowed. Print concatenates text
    /// (no printf formatting); Sha256 appends the lowercase digest of UTF-8 text
    /// (or decimal numeric text), not encryption. Unknown names, globals/kernel
    /// builtins, unsupported signatures/operands and oversized code fail here.
    ///
    /// This snapshots only reachable safe code/constants into a bounded host
    /// interpreter, not native guest machine code. It does not spawn a thread.
    pub fn prepare_handler(&self, name: &str, argument: u64) -> Result<HandlerTask, String> {
        if legacy_builtin_name(name)
            || matches!(name, "Yield" | "Throw" | "Sha256" | "ThreadCreate")
        {
            return Err("handler entry must be a registered non-builtin function".into());
        }
        if !self.fns.contains_key(name) {
            return Err("unknown registered handler".into());
        }
        let mut budget = PreparationBudget::default();
        let mut pending = vec![name];
        let mut ids = BTreeMap::from([(name, 0)]);
        let mut functions = Vec::new();
        // Iterative graph walk, including cycles: no Rust recursion in preparation.
        while let Some(name) = pending.get(functions.len()).copied() {
            let function = self.fns.get(name).ok_or("unknown registered handler")?;
            budget.charge(1, name.len())?;
            budget.charge(0, function.return_type.len())?;
            budget.charge(0, function.parameters.len())?;
            let parameter = handler_parameter(function)?;
            let mut body = Vec::new();
            for Stmt::Call { name, args } in &function.body {
                budget.charge(1, name.len())?;
                if args.len() > HANDLER_MAX_ARGS {
                    return Err("HolyC handler argument limit exceeded".into());
                }
                let mut operands = args
                    .iter()
                    .map(|arg| {
                        prepare_expr(
                            arg,
                            parameter.as_ref().map(|(_, name)| name.as_str()),
                            &self.consts,
                            &mut budget,
                        )
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let stmt = match name.as_str() {
                    "Print" => TaskStmt::Print(operands),
                    "Yield" if operands.is_empty() => TaskStmt::Yield,
                    "Throw" if operands.len() == 1 => TaskStmt::Throw(operands.remove(0)),
                    "Sha256" if operands.len() == 1 => TaskStmt::Sha256(operands.remove(0)),
                    "Yield" | "Throw" | "Sha256" => return Err("invalid task builtin arity".into()),
                    _ => {
                        if legacy_builtin_name(name) || name == "ThreadCreate" {
                            return Err("kernel/global builtin is not allowed in a handler".into());
                        }
                        if !self.fns.contains_key(name) {
                            return Err("unknown call in registered handler".into());
                        }
                        if operands.len() > 1
                            || operands.iter().any(|arg| matches!(arg, TaskExpr::Text(_)))
                        {
                            return Err(
                                "registered handler call requires at most one numeric argument"
                                    .into(),
                            );
                        }
                        let target = if let Some(id) = ids.get(name.as_str()) {
                            *id
                        } else {
                            let id = pending.len();
                            ids.insert(name.as_str(), id);
                            pending.push(name.as_str());
                            id
                        };
                        TaskStmt::Call {
                            target,
                            argument: operands.pop(),
                        }
                    }
                };
                body.push(stmt);
            }
            functions.push(TaskFunction {
                parameter: parameter.map(|(kind, _)| kind),
                body,
            });
        }
        for function in &functions {
            for stmt in &function.body {
                if let TaskStmt::Call { target, argument } = stmt {
                    if functions[*target].parameter.is_some() != argument.is_some() {
                        return Err("registered handler call arity mismatch".into());
                    }
                }
            }
        }
        let argument = functions[0]
            .parameter
            .map(|ty| Number::Unsigned(argument).cast(ty));
        Ok(HandlerTask {
            functions,
            stack: vec![TaskFrame {
                function: 0,
                pc: 0,
                argument,
            }],
            steps: 0,
            output: String::new(),
            result: None,
        })
    }

    /// Run `Adam` if present, else `KMain`.
    pub fn start(&mut self) -> Result<String, String> {
        if self.fns.contains_key("Adam") {
            self.call("Adam")
        } else if self.fns.contains_key("KMain") {
            self.call("KMain")
        } else if self.fns.contains_key("HolycInit") {
            self.call("HolycInit")
        } else {
            Ok(String::new())
        }
    }

    /// Invoke a named function (or builtin).
    pub fn call(&mut self, name: &str) -> Result<String, String> {
        self.call_args(name, &[])
    }

    fn call_args(&mut self, name: &str, args: &[Expr]) -> Result<String, String> {
        let mut out = String::new();
        let mut remaining = HANDLER_MAX_STEPS;
        self.call_bounded(name, args, 0, &mut remaining, &mut out)?;
        Ok(out)
    }

    // Legacy builtins retain their side effects and precedence. A shared budget
    // and output buffer stop recursion/exponential calls without stack overflow.
    fn call_bounded(
        &mut self,
        name: &str,
        args: &[Expr],
        depth: usize,
        remaining: &mut usize,
        out: &mut String,
    ) -> Result<(), String> {
        if depth >= HANDLER_MAX_DEPTH {
            return Err("HolyC call depth limit exceeded".into());
        }
        if *remaining == 0 {
            return Err("HolyC instruction limit exceeded".into());
        }
        *remaining -= 1;
        if let Some(text) = self.builtin(name, args)? {
            return append_bounded(out, &text, LEGACY_MAX_OUTPUT_BYTES);
        }
        let body = self
            .fns
            .get(name)
            .ok_or_else(|| format!("unknown fn {name}"))?
            .body
            .clone();
        for s in body {
            match s {
                Stmt::Call {
                    name: inner,
                    args: ia,
                } => self.call_bounded(&inner, &ia, depth + 1, remaining, out)?,
            }
        }
        Ok(())
    }

    fn builtin(&mut self, name: &str, args: &[Expr]) -> Result<Option<String>, String> {
        match name {
            "Print" => {
                let mut s = String::new();
                for a in args {
                    append_bounded(&mut s, &self.eval_str(a), LEGACY_MAX_OUTPUT_BYTES)?;
                }
                Ok(Some(s))
            }
            "Reboot" => {
                self.last_power = Some("reboot".into());
                Ok(Some("POWER-REBOOT\n".into()))
            }
            "Shutdown" => {
                self.last_power = Some("shutdown".into());
                Ok(Some("POWER-SHUTDOWN\n".into()))
            }
            "Wakeup" => {
                self.last_power = Some("wakeup".into());
                Ok(Some("POWER-WAKEUP\n".into()))
            }
            "LinuxHandoff" => {
                self.linux_booted = true;
                let mut s = String::from("POSTBOOT-LIVE\n");
                if self.net_delegates {
                    s.push_str("NET-DELEGATE\n");
                }
                if self.loopback {
                    s.push_str("LOOPBACK-MBOX\n");
                }
                if self.ssh_holyc {
                    s.push_str("SSH-HOLYC\n");
                }
                Ok(Some(s))
            }
            "ViewSection" => {
                let n = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("VIEW {n}\n")))
            }
            "WriteSection" => {
                let n = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                if self.linux_booted && self.immutable.iter().any(|i| i == &n) {
                    Ok(Some(format!("IMMUTABLE-DISABLED {n}\n")))
                } else {
                    Ok(Some(format!("WRITE {n}\n")))
                }
            }
            "TimerInit" => Ok(Some("TIMER-READY SBI-TIME\n".into())),
            "TlsHandshake" => Ok(Some("TLS-HELLO\n".into())),
            "TlsServerHello" => {
                let h = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "localhost".into());
                let ch = g6b_tls::client_hello(&h);
                let sh = g6b_tls::server_handshake(&ch)?;
                Ok(Some(format!(
                    "TLS-SERVERHELLO host={h} bytes={}\n",
                    sh.len()
                )))
            }
            "HttpsServe" => Ok(Some("HTTPS-SERVE files\n".into())),
            "FileServe" | "HttpFile" => {
                let path = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "/ui/index.html".into());
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!(
                    "FILE-SERVE {} {} bytes={}\n",
                    resp.status,
                    path,
                    resp.body.len()
                )))
            }
            "HttpsGet" => {
                let u = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("{}\n", g6b_tls::https_get(&u))))
            }
            "TlsClientHello" => {
                let h = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "localhost".into());
                let hello = g6b_tls::client_hello(&h);
                Ok(Some(format!(
                    "TLS-CLIENTHELLO host={h} bytes={} web={}\n",
                    hello.len(),
                    g6b_tls::is_web_compatible(&hello)
                )))
            }
            "CertParse" => {
                let _ = args;
                Ok(Some("CERT-OK algo=rsa\n".into()))
            }
            "RsaVerify" => Ok(Some("RSA-VERIFY PKCS1-SHA256\n".into())),
            "EcdsaVerify" => Ok(Some("ECDSA-VERIFY P256-SHA256\n".into())),
            "NetOpenPort" => {
                let kind = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("NET-OPEN {kind}\n")))
            }
            "RegisterEndpoint" => {
                let path = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                let method = args
                    .get(1)
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "GET".into());
                self.router.insert(
                    &method,
                    &path,
                    "holyc",
                    format!("{{\"origin\":\"holyc\",\"path\":\"{path}\"}}"),
                );
                Ok(Some(format!("EP-REG {method} {path}\n")))
            }
            "HttpHandle" => {
                let raw = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                match self.router.handle_bytes(raw.as_bytes()) {
                    Ok(b) => Ok(Some(format!("HTTP-OK bytes={}\n", b.len()))),
                    Err(e) => Ok(Some(format!("HTTP-ERR {e}\n"))),
                }
            }
            "KernelGet" => {
                let path = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                let path = if path.starts_with('/') {
                    path
                } else {
                    format!("/bios/{path}")
                };
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!(
                    "KERNEL-GET {} {}\n",
                    resp.status,
                    resp.body_str()
                )))
            }
            "SettingsExport" => {
                let via = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "uart".into());
                Ok(Some(format!("SETTINGS-EXPORT via={via}\n")))
            }
            "SettingsImport" => {
                let via = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "uart".into());
                Ok(Some(format!("SETTINGS-IMPORT via={via}\n")))
            }
            "FlashImage" => {
                let img = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "openwrt".into());
                Ok(Some(format!("FLASH-IMAGE {img}\n")))
            }
            "BiosUpdate" => Ok(Some("BIOS-UPDATE self\n".into())),
            "UsbKey" => {
                let op = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "present".into());
                Ok(Some(format!("USB-KEY {op}\n")))
            }
            "UsbLs" => {
                let kind = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "flash".into());
                Ok(Some(format!("USB-LS {kind}\n")))
            }
            "UsbFlash" => {
                let name = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "openwrt.bin".into());
                Ok(Some(format!("USB-FLASH fat32 {name}\n")))
            }
            "Menu" | "MenuCpu" | "MenuUncore" | "MenuMemory" | "MenuBoot" => {
                let path = match name {
                    "MenuCpu" => "/bios/menu/cpu".into(),
                    "MenuUncore" => "/bios/menu/uncore".into(),
                    "MenuMemory" => "/bios/menu/memory".into(),
                    "MenuBoot" => "/bios/menu/boot".into(),
                    _ => {
                        let id = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                        if id.is_empty() {
                            "/bios/menu".into()
                        } else {
                            format!("/bios/menu/{id}")
                        }
                    }
                };
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!("MENU {} {}\n", resp.status, resp.body_str())))
            }
            _ => Ok(None),
        }
    }

    fn eval_str(&self, e: &Expr) -> String {
        match e {
            Expr::Str(s) => s.clone(),
            Expr::Int(i) => i.to_string(),
            Expr::UInt(i) => i.to_string(),
            Expr::Var(v) => self
                .consts
                .get(v)
                .map(|n| n.to_string())
                .unwrap_or_default(),
        }
    }

    /// One dual-band REPL line. `Exit;` hangs up.
    pub fn repl(&mut self, line: &str) -> Result<ReplResult, String> {
        let t = line.trim();
        if t.is_empty() {
            return Ok(ReplResult::Output(String::new()));
        }
        if t.eq_ignore_ascii_case("exit")
            || t.eq_ignore_ascii_case("exit;")
            || t.eq_ignore_ascii_case("quit")
            || t.eq_ignore_ascii_case("quit;")
        {
            return Ok(ReplResult::Exit);
        }
        // `Name();` or `Name("arg");`
        let mut rest = t.trim_end_matches(';').trim();
        skip_ws(&mut rest);
        let name = take_ident(&mut rest).ok_or_else(|| format!("bad repl line: {t}"))?;
        skip_ws(&mut rest);
        let args = if rest.starts_with('(') {
            parse_arg_list(&mut rest)?
        } else {
            Vec::new()
        };
        let out = self.call_args(&name, &args)?;
        Ok(ReplResult::Output(out))
    }
}

/// Parse + run generated sources (Adam/KMain).
pub fn eval_src(src: &str) -> Result<String, String> {
    let mut p = Program::parse(src)?;
    p.start()
}

fn parse_string(rest: &mut &str) -> Result<String, String> {
    *rest = rest.strip_prefix('"').ok_or("expected string")?;
    let mut out = String::new();
    while let Some(c) = rest.chars().next() {
        *rest = &rest[c.len_utf8()..];
        match c {
            '"' => return Ok(out),
            '\n' | '\r' => return Err("unescaped newline in string".into()),
            '\\' => {
                let escape = rest.chars().next().ok_or("unterminated string escape")?;
                *rest = &rest[escape.len_utf8()..];
                match escape {
                    '\\' | '"' | '\'' | '?' | '/' => out.push(escape),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'b' => out.push('\u{8}'),
                    'f' => out.push('\u{c}'),
                    'v' => out.push('\u{b}'),
                    '0' => out.push('\0'),
                    'x' => {
                        let digits = rest.get(..2).ok_or("incomplete hex string escape")?;
                        if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
                            return Err("invalid hex string escape".into());
                        }
                        let value = u8::from_str_radix(digits, 16)
                            .map_err(|_| "invalid hex string escape")?;
                        out.push(char::from(value));
                        *rest = &rest[2..];
                    }
                    '\n' => {}
                    '\r' => {
                        if let Some(tail) = rest.strip_prefix('\n') {
                            *rest = tail;
                        }
                    }
                    _ => return Err("unsupported string escape".into()),
                }
            }
            _ => out.push(c),
        }
    }
    Err("unterminated string".into())
}

fn strip_comments(src: &str) -> Result<String, String> {
    let mut out = String::new();
    let mut rest = src;
    while !rest.is_empty() {
        if rest.starts_with('"') {
            let start = rest;
            parse_string(&mut rest)?;
            out.push_str(&start[..start.len() - rest.len()]);
        } else if let Some(tail) = rest.strip_prefix("//") {
            rest = &tail[tail.find(['\n', '\r']).unwrap_or(tail.len())..];
            out.push(' ');
        } else if let Some(tail) = rest.strip_prefix("/*") {
            let end = tail.find("*/").ok_or("unterminated block comment")?;
            out.push(' ');
            out.extend(tail[..end].chars().filter(|c| matches!(c, '\n' | '\r')));
            rest = &tail[end + 2..];
        } else {
            let c = rest.chars().next().ok_or("unexpected end of source")?;
            out.push(c);
            rest = &rest[c.len_utf8()..];
        }
    }
    Ok(out)
}

fn skip_ws(rest: &mut &str) {
    *rest = rest.trim_start();
}

fn skip_line(rest: &mut &str) {
    if let Some(i) = rest.find('\n') {
        *rest = &rest[i + 1..];
    } else {
        *rest = "";
    }
}

fn take_ident(rest: &mut &str) -> Option<String> {
    skip_ws(rest);
    let s = *rest;
    let mut n = 0;
    for c in s.chars() {
        if n == 0 {
            if c.is_ascii_alphabetic() || c == '_' {
                n += c.len_utf8();
            } else {
                break;
            }
        } else if c.is_ascii_alphanumeric() || c == '_' {
            n += c.len_utf8();
        } else {
            break;
        }
    }
    if n == 0 {
        return None;
    }
    let id = s[..n].to_string();
    *rest = &s[n..];
    Some(id)
}

fn parse_define(p: &mut Program, rest: &mut &str) -> Result<(), String> {
    *rest = rest.trim_start_matches("#define").trim_start();
    let name = take_ident(rest).ok_or("bad #define")?;
    skip_ws(rest);
    let mut n = 0i64;
    let s = *rest;
    let mut i = 0;
    while s
        .as_bytes()
        .get(i)
        .map(|b| b.is_ascii_digit())
        .unwrap_or(false)
    {
        n = n
            .checked_mul(10)
            .and_then(|n| n.checked_add(i64::from(s.as_bytes()[i] - b'0')))
            .ok_or("integer literal out of range")?;
        i += 1;
    }
    p.consts.insert(name, n);
    skip_line(rest);
    Ok(())
}

fn parse_fn(p: &mut Program, rest: &mut &str) -> Result<(), String> {
    skip_ws(rest);
    // type: U0 / INative / U8 / I64
    let return_type = take_ident(rest).ok_or("expected type")?;
    skip_ws(rest);
    let name = take_ident(rest).ok_or("expected fn name")?;
    skip_ws(rest);
    if !rest.starts_with('(') {
        return Err(format!("expected ( after {name}"));
    }
    let end = rest.find(')').ok_or("unterminated fn parameters")?;
    let parameters = rest[1..end].to_string();
    *rest = rest[end + 1..].trim_start();
    skip_ws(rest);
    if !rest.starts_with('{') {
        return Err(format!("expected {{ for {name}"));
    }
    *rest = &rest[1..];
    let mut stmts = Vec::new();
    loop {
        skip_ws(rest);
        if rest.starts_with('}') {
            *rest = &rest[1..];
            break;
        }
        if rest.is_empty() {
            return Err(format!("unterminated fn {name}"));
        }
        stmts.push(parse_stmt(rest)?);
    }
    p.fns.insert(
        name,
        Function {
            return_type,
            parameters,
            body: stmts,
        },
    );
    Ok(())
}

fn parse_stmt(rest: &mut &str) -> Result<Stmt, String> {
    skip_ws(rest);
    let name = take_ident(rest).ok_or("expected stmt")?;
    skip_ws(rest);
    let args = if rest.starts_with('(') {
        parse_arg_list(rest)?
    } else {
        Vec::new()
    };
    skip_ws(rest);
    if rest.starts_with(';') {
        *rest = &rest[1..];
    }
    Ok(Stmt::Call { name, args })
}

fn parse_arg_list(rest: &mut &str) -> Result<Vec<Expr>, String> {
    if !rest.starts_with('(') {
        return Ok(Vec::new());
    }
    *rest = &rest[1..];
    let mut args = Vec::new();
    loop {
        skip_ws(rest);
        if rest.starts_with(')') {
            *rest = &rest[1..];
            break;
        }
        if rest.is_empty() {
            return Err("unterminated arg list".into());
        }
        args.push(parse_expr(rest)?);
        skip_ws(rest);
        if rest.starts_with(',') {
            *rest = &rest[1..];
        }
    }
    Ok(args)
}

fn parse_expr(rest: &mut &str) -> Result<Expr, String> {
    skip_ws(rest);
    if rest.starts_with('"') {
        return parse_string(rest).map(Expr::Str);
    }
    if rest.starts_with('-') || rest.as_bytes().first().is_some_and(u8::is_ascii_digit) {
        let s = *rest;
        let negative = s.starts_with('-');
        let start = usize::from(negative);
        let end = start + s[start..].bytes().take_while(u8::is_ascii_digit).count();
        if end == start {
            return Err("expected integer digits".into());
        }
        let expr = if negative {
            Expr::Int(
                s[..end]
                    .parse()
                    .map_err(|_| "integer literal out of range")?,
            )
        } else {
            let n: u64 = s[..end]
                .parse()
                .map_err(|_| "integer literal out of range")?;
            match i64::try_from(n) {
                Ok(n) => Expr::Int(n),
                Err(_) => Expr::UInt(n),
            }
        };
        *rest = &s[end..];
        return Ok(expr);
    }
    let id = take_ident(rest).ok_or("expected expr")?;
    Ok(Expr::Var(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thread_request_validates_the_entire_command_without_spawning() {
        assert_eq!(
            parse_thread_request(" \n ThreadCreate(\"Handler_1\", 123); \t").unwrap(),
            ThreadRequest {
                handler: "Handler_1".into(),
                argument: 123
            }
        );
        assert_eq!(
            parse_thread_request("ThreadCreate(\"Handler\", 18446744073709551615)")
                .unwrap()
                .argument,
            u64::MAX
        );
        assert_eq!(
            parse_thread_request("ThreadCreate(\"Handler\", 0)")
                .unwrap()
                .argument,
            0
        );
        for source in [
            "",
            "ThreadCreate",
            "ThreadCreateOther(\"Handler\", 0)",
            "ThreadCreate(Handler, 0)",
            "ThreadCreate(\"\", 0)",
            "ThreadCreate(\"1Handler\", 0)",
            "ThreadCreate(\" Handler\", 0)",
            "ThreadCreate(\"Handler \", 0)",
            "ThreadCreate(\"Hé\", 0)",
            "ThreadCreate(\"Handler();\", 0)",
            "ThreadCreate(\"Handler\", -1)",
            "ThreadCreate(\"Handler\", -0)",
            "ThreadCreate(\"Handler\", +1)",
            "ThreadCreate(\"Handler\", 18446744073709551616)",
            "ThreadCreate(\"Handler\", \"123\")",
            "ThreadCreate(\"Handler\", arg)",
            "ThreadCreate(\"Handler\", 1+2)",
            "ThreadCreate(\"Handler\", 0x10)",
            "ThreadCreate(\"Handler\" 123)",
            "ThreadCreate(\"Handler\",)",
            "ThreadCreate(\"Handler\", 1,)",
            "ThreadCreate(\"Handler\", 1, 2)",
            "ThreadCreate(\"Handler\", 1",
            "ThreadCreate(\"Handler\", 1));",
            "ThreadCreate(\"Handler\", 1);;",
            "ThreadCreate(\"Handler\", 1) junk",
            "ThreadCreate(\"Handler\", 1); Reboot();",
            "ThreadCreate(\"Handler\", 1) // comment",
        ] {
            assert!(parse_thread_request(source).is_err(), "{source}");
        }
        assert!(parse_thread_request(&" ".repeat(THREAD_REQUEST_MAX_BYTES + 1)).is_err());
        let mut program = Program::parse("U0 Handler() { Print(\"run\"); }").unwrap();
        assert!(program.repl("ThreadCreate(\"Handler\", 1)").is_err());
    }

    #[test]
    fn handler_yields_resumes_and_owns_its_argument_and_code() {
        let program = Program::parse(
            r#"
#define arg 99
U0 Handler(U64 arg) { Print("start:", arg); Yield(); Child(arg); Print(":end"); }
U0 Child(U64 value) { Print(":child:", value); Yield(); Print(":resumed"); }
"#,
        )
        .unwrap();
        let mut task = program.prepare_handler("Handler", 123).unwrap();
        drop(program);
        assert_eq!(task.poll(0), HandlerPoll::Yielded);
        assert_eq!(task.steps, 0);
        assert!(task.output.is_empty());
        assert_eq!(task.poll(2), HandlerPoll::Yielded);
        assert_eq!(task.output, "start:123");
        assert_eq!(task.steps, 2);
        assert_eq!(task.poll(1), HandlerPoll::Yielded);
        assert_eq!(task.stack.len(), 2);
        assert_eq!(task.poll(usize::MAX), HandlerPoll::Yielded);
        assert_eq!(task.output, "start:123:child:123");
        let expected = HandlerPoll::Finished(Ok("start:123:child:123:resumed:end".into()));
        assert_eq!(task.poll(usize::MAX), expected);
        let steps = task.steps;
        assert_eq!(task.poll(0), expected);
        assert_eq!(task.poll(usize::MAX), expected);
        assert_eq!(task.steps, steps);
    }

    #[test]
    fn handler_scalar_conversions_preserve_all_opaque_bits() {
        let program = Program::parse(r#"
#define N 7
U0 Handler(U64 arg) { Print(arg, ":"); Signed(arg); Unsigned(-1); Signed(-9223372036854775808); Print(N); }
U0 Signed(I64 value) { Print(value, ":"); }
U0 Unsigned(U64 value) { Print(value, ":"); }
U0 NoArg() { Print("none"); }
"#).unwrap();
        assert_eq!(
            program
                .prepare_handler("Handler", u64::MAX)
                .unwrap()
                .poll(100),
            HandlerPoll::Finished(Ok(
                "18446744073709551615:-1:18446744073709551615:-9223372036854775808:7".into()
            ))
        );
        assert_eq!(
            program
                .prepare_handler("Signed", u64::MAX)
                .unwrap()
                .poll(100),
            HandlerPoll::Finished(Ok("-1:".into()))
        );
        assert_eq!(
            program
                .prepare_handler("NoArg", u64::MAX)
                .unwrap()
                .poll(100),
            HandlerPoll::Finished(Ok("none".into()))
        );
    }

    #[test]
    fn handler_preparation_rejects_unsafe_calls_even_after_throw() {
        for source in [
            "U0 Handler() { Print(\"before\"); Reboot(); }",
            "U0 Handler() { Throw(\"stop\"); UnknownBuiltin(); }",
            "U0 Handler() { Child(); } U0 Child() { LinuxHandoff(); }",
            "U0 Handler() { RegisterEndpoint(\"/bad\"); }",
            "U0 Handler() { KernelGet(\"/bios\"); }",
            "U0 Handler() { ThreadCreate(\"Child\", 0); } U0 Child() {}",
            "U0 Handler() { Reboot(); } U0 Reboot() {}",
            "U0 Handler() { Print(unknown_global); }",
        ] {
            let program = Program::parse(source).unwrap();
            assert!(program.prepare_handler("Handler", 0).is_err(), "{source}");
            assert_eq!(program.last_power, None);
            assert!(!program.linux_booted);
        }
        let program =
            Program::parse("U0 Safe() {} U0 Unsafe() { Reboot(); } U0 Reboot() {}").unwrap();
        assert_eq!(
            program.prepare_handler("Safe", 0).unwrap().poll(1),
            HandlerPoll::Finished(Ok(String::new()))
        );
        assert!(program.prepare_handler("Missing", 0).is_err());
        assert!(program.prepare_handler("Reboot", 0).is_err());
        assert!(program.prepare_handler("Print", 0).is_err());
    }

    #[test]
    fn handler_preparation_checks_signatures_arity_and_operand_types() {
        for source in [
            "I64 Handler() {}",
            "U0 Handler(U8 *arg) {}",
            "U0 Handler(U64) {}",
            "U0 Handler(U64 a, I64 b) {}",
            "U0 Handler() { Child(); } U0 Child(U64 arg) {}",
            "U0 Handler() { Child(1); } U0 Child() {}",
            "U0 Handler() { Child(\"x\"); } U0 Child(U64 arg) {}",
            "U0 Handler() { Child(1, 2); } U0 Child(U64 arg) {}",
            "U0 Handler() { Child(); } I64 Child() {}",
            "U0 Handler() { Yield(1); }",
            "U0 Handler() { Throw(); }",
            "U0 Handler() { Throw(1, 2); }",
            "U0 Handler() { Sha256(); }",
            "U0 Handler() { Sha256(1, 2); }",
        ] {
            assert!(
                Program::parse(source)
                    .unwrap()
                    .prepare_handler("Handler", 0)
                    .is_err(),
                "{source}"
            );
        }
        let source = format!(
            "U0 Handler() {{ Print({}); }}",
            vec!["0"; HANDLER_MAX_ARGS + 1].join(",")
        );
        assert!(Program::parse(&source)
            .unwrap()
            .prepare_handler("Handler", 0)
            .is_err());
        // Boot declarations outside the safe subset still parse and run as before.
        let mut program = Program::parse("U0 Legacy(U8 *name) { Print(\"legacy\"); }").unwrap();
        assert_eq!(program.call("Legacy").unwrap(), "legacy");
    }

    #[test]
    fn handler_catchless_throw_is_terminal_and_discards_output() {
        let program = Program::parse("U0 Handler(U64 arg) { Print(\"discard\"); Child(arg); Print(\"never\"); } U0 Child(U64 value) { Yield(); Throw(value); }").unwrap();
        let mut task = program.prepare_handler("Handler", 123).unwrap();
        assert_eq!(task.poll(100), HandlerPoll::Yielded);
        let expected = HandlerPoll::Finished(Err("HolyC exception: 123".into()));
        assert_eq!(task.poll(100), expected);
        assert!(task.output.is_empty());
        assert!(task.stack.is_empty());
        assert_eq!(task.poll(100), expected);
    }

    #[test]
    fn handler_sha256_is_a_digest_not_encryption() {
        let program =
            Program::parse(r#"U0 Handler() { Sha256("abc"); Yield(); Sha256(""); }"#).unwrap();
        let mut task = program.prepare_handler("Handler", 0).unwrap();
        assert_eq!(task.poll(100), HandlerPoll::Yielded);
        assert_eq!(
            task.poll(100),
            HandlerPoll::Finished(Ok(concat!(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
            .into()))
        );
        assert!(Program::parse("U0 Handler() { Encrypt(\"abc\"); }")
            .unwrap()
            .prepare_handler("Handler", 0)
            .is_err());
    }

    #[test]
    fn handler_depth_is_bounded_across_recursive_yields() {
        let program = Program::parse(
            "U0 Handler(U64 arg) { Yield(); Child(arg); } U0 Child(U64 arg) { Handler(arg); }",
        )
        .unwrap();
        let mut task = program.prepare_handler("Handler", 1).unwrap();
        for _ in 0..HANDLER_MAX_DEPTH / 2 {
            assert_eq!(task.poll(usize::MAX), HandlerPoll::Yielded);
        }
        assert_eq!(
            task.poll(usize::MAX),
            HandlerPoll::Finished(Err("HolyC call depth limit exceeded".into()))
        );
    }

    fn binary_call_program(leaf: &str) -> String {
        let mut source = format!("U0 F0() {{ {leaf} }}\n");
        for level in 1..=16 {
            source.push_str(&format!(
                "U0 F{level}() {{ F{}(); F{}(); }}\n",
                level - 1,
                level - 1
            ));
        }
        source
    }

    #[test]
    fn handler_lifetime_instruction_budget_survives_every_poll_and_yield() {
        let program = Program::parse(&binary_call_program("Yield();")).unwrap();
        let mut task = program.prepare_handler("F16", 0).unwrap();
        for _ in 0..=HANDLER_MAX_STEPS {
            let before = task.steps;
            let polled = task.poll(7);
            assert!(task.steps - before <= 7);
            if polled != HandlerPoll::Yielded {
                assert_eq!(
                    polled,
                    HandlerPoll::Finished(Err("HolyC instruction limit exceeded".into()))
                );
                assert_eq!(task.steps, HANDLER_MAX_STEPS);
                return;
            }
        }
        panic!("handler exceeded lifetime budget");
    }

    #[test]
    fn handler_output_and_exception_results_are_bounded() {
        let text = "x".repeat(HANDLER_MAX_OUTPUT_BYTES);
        let program = Program::parse(&format!("U0 Exact() {{ Print(\"{text}\"); }} U0 Over() {{ Print(\"{text}\"); Print(\"x\"); }} U0 Fail() {{ Throw(\"{text}\"); }}")).unwrap();
        assert_eq!(
            program.prepare_handler("Exact", 0).unwrap().poll(10),
            HandlerPoll::Finished(Ok(text))
        );
        for handler in ["Over", "Fail"] {
            let mut task = program.prepare_handler(handler, 0).unwrap();
            assert_eq!(
                task.poll(10),
                HandlerPoll::Finished(Err("HolyC output limit exceeded".into()))
            );
            assert!(task.output.is_empty());
        }
        let available = HANDLER_MAX_OUTPUT_BYTES - "HolyC exception: ".len();
        let mut text = "é".repeat(available / 2);
        text.push_str(&"x".repeat(available % 2));
        let program = Program::parse(&format!("U0 Handler() {{ Throw(\"{text}\"); }}")).unwrap();
        let HandlerPoll::Finished(Err(error)) =
            program.prepare_handler("Handler", 0).unwrap().poll(10)
        else {
            panic!("expected bounded exception")
        };
        assert_eq!(error.len(), HANDLER_MAX_OUTPUT_BYTES);
    }

    #[test]
    fn handler_preparation_code_and_literal_sizes_are_bounded() {
        for source in [
            format!(
                "U0 Handler() {{ Print(\"{}\"); }}",
                "x".repeat(HANDLER_MAX_OUTPUT_BYTES + 1)
            ),
            format!(
                "U0 Handler() {{ {} }}",
                "Yield();".repeat(HANDLER_MAX_CODE_UNITS)
            ),
            format!(
                "U0 Handler() {{ {} }}",
                format!("Print(\"{}\");", "x".repeat(HANDLER_MAX_OUTPUT_BYTES)).repeat(5)
            ),
        ] {
            assert!(Program::parse(&source)
                .unwrap()
                .prepare_handler("Handler", 0)
                .is_err());
        }
    }

    #[test]
    fn legacy_calls_and_integer_parsing_have_safety_budgets() {
        let mut recursive = Program::parse("U0 Handler() { Handler(); }").unwrap();
        assert_eq!(
            recursive.call("Handler"),
            Err("HolyC call depth limit exceeded".into())
        );
        let mut exponential = Program::parse(&binary_call_program("Print(\"\");")).unwrap();
        assert_eq!(
            exponential.call("F16"),
            Err("HolyC instruction limit exceeded".into())
        );
        let mut output = Program::parse(&binary_call_program(&format!(
            "Print(\"{}\");",
            "x".repeat(1024)
        )))
        .unwrap();
        assert_eq!(
            output.call("F16"),
            Err("HolyC output limit exceeded".into())
        );
        for source in [
            "U0 Handler() { Print(18446744073709551616); }",
            "U0 Handler() { Print(-9223372036854775809); }",
            "#define N 9223372036854775808\nU0 Handler() {}",
        ] {
            assert!(Program::parse(source).is_err(), "{source}");
        }
    }

    #[test]
    fn menu_print_preserves_unicode_quotes_urls_and_literal_escapes() {
        let source = r#"
// Generated menu "quote in comment"
U0 MenuMainPrint() {
    Print("  product=Board \"α\" https://local\nnext\\n literal\t\r\x01\0\n");
    Print("\"); Reboot(); /* still data */ // still data\n");
}
"#;
        let mut program = Program::parse(source).unwrap();
        assert_eq!(program.call("MenuMainPrint").unwrap(), "  product=Board \"α\" https://local\nnext\\n literal\t\r\u{1}\0\n\"); Reboot(); /* still data */ // still data\n");
        assert_eq!(program.last_power, None);
        assert_eq!(
            program.repl(r#"Print("https://local/α\\n");"#).unwrap(),
            ReplResult::Output("https://local/α\\n".into())
        );
    }

    #[test]
    fn comments_preserve_string_boundaries_and_reject_unterminated_input() {
        let source = "/* lead */ U0 /* boundary */ KMain() { Print(\"é/*not a comment*/\"); /* gap\n */ Print(\"https://local\"); } // tail";
        assert_eq!(eval_src(source).unwrap(), "é/*not a comment*/https://local");
        for source in [
            "U0 KMain() { Print(\"open); }",
            "U0 KMain() { Print(\"line\nbreak\"); }",
            "U0 KMain() {} /* open",
            r#"U0 KMain() { Print("\xQ0"); }"#,
            r#"U0 KMain() { Print("\q"); }"#,
        ] {
            assert!(Program::parse(source).is_err(), "{source}");
        }
    }

    #[test]
    fn kmain_fast_init() {
        let src = r#"
U0 HolycInit() { Print("HOLYC-READY\n"); }
U0 UiBoot() { Print("UI-BOOT\n"); }
U0 KMain() { Print("G6LC-BIOS\n"); HolycInit(); UiBoot(); }
U0 Adam() { KMain(); }
"#;
        let out = eval_src(src).unwrap();
        assert!(out.contains("G6LC-BIOS"), "{out}");
        assert!(out.contains("HOLYC-READY"), "{out}");
        assert!(out.contains("UI-BOOT"), "{out}");
    }

    #[test]
    fn postboot_immutable_write_disabled() {
        let mut p = Program::parse(
            r#"
U0 LinuxHandoff() { Print("x"); }
U0 WriteSection(U8 *name) { Print("x"); }
"#,
        )
        .unwrap();
        let _ = p.call("LinuxHandoff").unwrap();
        assert!(p.linux_booted);
        let w = p
            .call_args("WriteSection", &[Expr::Str("config".into())])
            .unwrap();
        assert!(w.contains("IMMUTABLE-DISABLED"), "{w}");
        let v = p
            .call_args("ViewSection", &[Expr::Str("config".into())])
            .unwrap();
        assert!(v.contains("VIEW config"), "{v}");
    }

    #[test]
    fn repl_power_and_exit() {
        let mut p = Program::default();
        match p.repl("Reboot();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("POWER-REBOOT"), "{s}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(p.last_power.as_deref(), Some("reboot"));
        assert_eq!(p.repl("Exit;").unwrap(), ReplResult::Exit);
    }

    #[test]
    fn https_get_stub() {
        let mut p = Program::default();
        match p.repl(r#"HttpsGet("https://gsys.dev/");"#).unwrap() {
            ReplResult::Output(s) => {
                assert!(s.contains("HTTPS-GET"), "{s}");
                assert!(s.contains("gsys.dev"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        match p.repl("TlsHandshake();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("TLS-HELLO"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"NetOpenPort("bios-https");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("NET-OPEN bios-https"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"TlsClientHello("gsys.dev");"#).unwrap() {
            ReplResult::Output(s) => {
                assert!(s.contains("TLS-CLIENTHELLO"), "{s}");
                assert!(s.contains("web=true"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        match p.repl("RsaVerify();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("RSA-VERIFY"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl("EcdsaVerify();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("ECDSA-VERIFY"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl("CertParse();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("CERT-OK"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"TlsServerHello("localhost");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("TLS-SERVERHELLO"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"UsbFlash("openwrt.bin");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("USB-FLASH fat32"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"UsbLs("ntfs");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("USB-LS ntfs"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"FlashImage("openwrt");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("FLASH-IMAGE openwrt"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"SettingsExport("usb");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("SETTINGS-EXPORT via=usb"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"RegisterEndpoint("/bios/custom");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("EP-REG"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p
            .repl(r#"HttpHandle("GET /bios/custom HTTP/1.1\r\n\r\n");"#)
            .unwrap()
        {
            ReplResult::Output(s) => assert!(s.contains("HTTP-OK"), "{s}"),
            other => panic!("{other:?}"),
        }
    }
}
