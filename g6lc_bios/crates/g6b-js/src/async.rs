// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use super::{dom_step, op_size, reserved, run_dom, tokenize, DomProgram, Op, Parser, TokenKind};
use g6b_dom::Node;
use std::collections::{BTreeMap, VecDeque};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsyncLimit {
    Tasks,
    SourceBytes,
    ProgramSteps,
    ProgramTextBytes,
    ResponseBytes,
    TaskSteps,
    TickSteps,
}

impl fmt::Display for AsyncLimit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "async {self:?} limit")
    }
}

impl std::error::Error for AsyncLimit {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AsyncLimits {
    pub max_tasks: usize,
    pub max_source_bytes: usize,
    pub max_program_steps: usize,
    pub max_program_text_bytes: usize,
    pub max_response_bytes: usize,
    pub max_task_steps: usize,
    pub steps_per_tick: usize,
}

impl Default for AsyncLimits {
    fn default() -> Self {
        Self {
            max_tasks: 16,
            max_source_bytes: 65_536,
            max_program_steps: 4096,
            max_program_text_bytes: 65_536,
            max_response_bytes: 16_384,
            max_task_steps: 8192,
            steps_per_tick: 64,
        }
    }
}

impl AsyncLimits {
    pub fn validate(self) -> Result<(), AsyncLimit> {
        for (value, ceiling, limit) in [
            (self.max_tasks, 256, AsyncLimit::Tasks),
            (self.max_source_bytes, 1_048_576, AsyncLimit::SourceBytes),
            (self.max_program_steps, 16_384, AsyncLimit::ProgramSteps),
            (
                self.max_program_text_bytes,
                4_194_304,
                AsyncLimit::ProgramTextBytes,
            ),
            (
                self.max_response_bytes,
                1_048_576,
                AsyncLimit::ResponseBytes,
            ),
            (self.max_task_steps, 65_536, AsyncLimit::TaskSteps),
            (self.steps_per_tick, 1024, AsyncLimit::TickSteps),
        ] {
            if value == 0 || value > ceiling {
                return Err(limit);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsyncCompileError {
    Syntax(String),
    Limit(AsyncLimit),
    InvalidLimits(AsyncLimit),
}

impl fmt::Display for AsyncCompileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax(message) => f.write_str(message),
            Self::Limit(limit) => write!(f, "{limit} exceeded"),
            Self::InvalidLimits(limit) => write!(f, "invalid {limit}"),
        }
    }
}

impl std::error::Error for AsyncCompileError {}

impl From<String> for AsyncCompileError {
    fn from(message: String) -> Self {
        Self::Syntax(message)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TextValue {
    Literal(String),
    Caught,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Instruction {
    EnterTry { catch: usize },
    LeaveTry { end: usize },
    ClearCatch,
    AwaitFetch { method: String, url: String },
    Throw(TextValue),
    Log(TextValue),
    Dom(DomProgram),
    Finish,
}

impl Instruction {
    fn text_bytes(&self) -> usize {
        match self {
            Self::AwaitFetch { method, url } => method.len() + url.len(),
            Self::Throw(TextValue::Literal(value)) | Self::Log(TextValue::Literal(value)) => {
                value.len()
            }
            Self::Dom(program) => program.steps.iter().map(super::DomStep::size).sum(),
            _ => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AsyncProgram {
    code: Vec<Instruction>,
    text_bytes: usize,
}

impl AsyncProgram {
    pub fn instruction_count(&self) -> usize {
        self.code.len()
    }

    pub fn text_bytes(&self) -> usize {
        self.text_bytes
    }
}

pub fn compile_async(source: &str) -> Result<AsyncProgram, AsyncCompileError> {
    compile_async_with_limits(source, AsyncLimits::default())
}

pub fn compile_async_with_limits(
    source: &str,
    limits: AsyncLimits,
) -> Result<AsyncProgram, AsyncCompileError> {
    limits
        .validate()
        .map_err(AsyncCompileError::InvalidLimits)?;
    if source.len() > limits.max_source_bytes {
        return Err(AsyncCompileError::Limit(AsyncLimit::SourceBytes));
    }
    let mut compiler = AsyncCompiler {
        parser: Parser {
            tokens: tokenize(source)?,
            pos: 0,
            bindings: BTreeMap::new(),
            binding_bytes: 0,
            dom_program: DomProgram::default(),
            dom_bytes: 0,
            handles: 0,
        },
        program: AsyncProgram {
            code: Vec::new(),
            text_bytes: 0,
        },
        limits,
    };
    compiler.block(false, None)?;
    compiler.push(Instruction::Finish)?;
    Ok(compiler.program)
}

struct AsyncCompiler {
    parser: Parser,
    program: AsyncProgram,
    limits: AsyncLimits,
}

impl AsyncCompiler {
    fn error(&self, message: &str) -> AsyncCompileError {
        AsyncCompileError::Syntax(self.parser.error(message))
    }

    fn push(&mut self, instruction: Instruction) -> Result<usize, AsyncCompileError> {
        if self.program.code.len() >= self.limits.max_program_steps {
            return Err(AsyncCompileError::Limit(AsyncLimit::ProgramSteps));
        }
        let bytes = self
            .program
            .text_bytes
            .saturating_add(instruction.text_bytes());
        if bytes > self.limits.max_program_text_bytes {
            return Err(AsyncCompileError::Limit(AsyncLimit::ProgramTextBytes));
        }
        self.program.text_bytes = bytes;
        let index = self.program.code.len();
        self.program.code.push(instruction);
        Ok(index)
    }

    fn text_value(&mut self, binding: Option<&str>) -> Result<TextValue, AsyncCompileError> {
        if let TokenKind::Ident(name) = self.parser.peek() {
            if Some(name.as_str()) == binding {
                self.parser.pos += 1;
                return Ok(TextValue::Caught);
            }
        }
        Ok(TextValue::Literal(self.parser.text()?))
    }

    fn block(&mut self, braced: bool, binding: Option<&str>) -> Result<(), AsyncCompileError> {
        loop {
            if self.parser.peek() == &TokenKind::End {
                return if braced {
                    Err(self.error("unterminated async block"))
                } else {
                    Ok(())
                };
            }
            if braced && self.parser.punct('}') {
                return Ok(());
            }
            if self.parser.punct(';') {
                continue;
            }
            let first = self.parser.ident()?;
            if first == "try" {
                if braced {
                    return Err(self.error("nested try/catch is outside the async subset"));
                }
                self.try_catch()?;
                continue;
            }
            let instruction = match first.as_str() {
                "await" => {
                    self.parser.named("fetch")?;
                    let Op::Fetch { method, url } = self.parser.statement("fetch")? else {
                        return Err(self.error("await requires fetch"));
                    };
                    if !url.starts_with("/bios/")
                        || url.chars().any(|c| c.is_control() || c == '\\')
                    {
                        return Err(self.error(
                            "async fetch requires a /bios/ URL without controls or backslashes",
                        ));
                    }
                    Instruction::AwaitFetch { method, url }
                }
                "throw" => {
                    if self.parser.tokens[self.parser.pos].line_before {
                        return Err(self.error("line terminator after throw"));
                    }
                    Instruction::Throw(self.text_value(binding)?)
                }
                "console" => {
                    self.parser.expect('.')?;
                    self.parser.named("log")?;
                    self.parser.expect('(')?;
                    let value = self.text_value(binding)?;
                    self.parser.expect(')')?;
                    Instruction::Log(value)
                }
                "document" => {
                    let op = self.parser.statement("document")?;
                    if self.parser.handles != 0 || !self.parser.dom_program.steps.is_empty() {
                        return Err(self.error("DOM handles are outside the async subset"));
                    }
                    if op_size(&op) > self.limits.max_program_text_bytes {
                        return Err(AsyncCompileError::Limit(AsyncLimit::ProgramTextBytes));
                    }
                    let step = dom_step(&op)
                        .ok_or_else(|| self.error("unsupported async DOM operation"))?;
                    Instruction::Dom(DomProgram { steps: vec![step] })
                }
                _ => return Err(self.error("unsupported async statement")),
            };
            self.push(instruction)?;
            if self.parser.punct(';')
                || self.parser.peek() == &TokenKind::End
                || (braced && self.parser.peek() == &TokenKind::Punct('}'))
                || (self.parser.tokens[self.parser.pos].line_before
                    && matches!(self.parser.peek(), TokenKind::Ident(_)))
            {
                continue;
            }
            return Err(self.error("expected async statement separator"));
        }
    }

    fn try_catch(&mut self) -> Result<(), AsyncCompileError> {
        self.parser.expect('{')?;
        let enter = self.push(Instruction::EnterTry { catch: 0 })?;
        self.block(true, None)?;
        let leave = self.push(Instruction::LeaveTry { end: 0 })?;
        self.parser.named("catch")?;
        self.parser.expect('(')?;
        let binding = self.parser.ident()?;
        if reserved(&binding) || binding == "await" {
            return Err(self.error("reserved catch binding"));
        }
        self.parser.expect(')')?;
        self.parser.expect('{')?;
        self.program.code[enter] = Instruction::EnterTry {
            catch: self.program.code.len(),
        };
        self.block(true, Some(&binding))?;
        self.push(Instruction::ClearCatch)?;
        self.program.code[leave] = Instruction::LeaveTry {
            end: self.program.code.len(),
        };
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TaskId(u64);

impl TaskId {
    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RequestToken {
    task: TaskId,
    continuation: usize,
}

impl RequestToken {
    pub fn task(self) -> TaskId {
        self.task
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JsExceptionKind {
    Thrown,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsException {
    pub kind: JsExceptionKind,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsyncTrap {
    StepBudget,
    ResponseBudget,
    Dom(String),
    InvalidState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsyncFailure {
    Exception(JsException),
    Trap(AsyncTrap),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsyncSpawnError {
    QueueFull,
    ProgramLimit(AsyncLimit),
    IdExhausted,
}

impl fmt::Display for AsyncSpawnError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "async admission failed: {self:?}")
    }
}

impl std::error::Error for AsyncSpawnError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompletionStatus {
    Accepted,
    Discarded,
    LimitExceeded,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsyncEvent {
    Request {
        task: TaskId,
        token: RequestToken,
        method: String,
        url: String,
    },
    Log {
        task: TaskId,
        value: String,
    },
    Finished {
        task: TaskId,
        result: Result<(), AsyncFailure>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AsyncTick {
    pub events: Vec<AsyncEvent>,
    pub steps: usize,
    pub ready: usize,
    pub pending: usize,
}

#[derive(Debug)]
struct Task {
    program: AsyncProgram,
    pc: usize,
    handler: Option<usize>,
    caught: Option<JsException>,
    pending: Option<RequestToken>,
    resume: Option<Result<(), AsyncFailure>>,
    steps_left: usize,
}

enum Progress {
    Ready,
    Waiting,
    Finished(Result<(), AsyncFailure>),
}

impl Task {
    fn trap(trap: AsyncTrap) -> Progress {
        Progress::Finished(Err(AsyncFailure::Trap(trap)))
    }

    fn raise(&mut self, exception: JsException) -> Progress {
        if let Some(catch) = self.handler.take() {
            self.caught = Some(exception);
            self.pc = catch;
            Progress::Ready
        } else {
            Progress::Finished(Err(AsyncFailure::Exception(exception)))
        }
    }

    fn text(&self, value: TextValue) -> Result<String, AsyncTrap> {
        match value {
            TextValue::Literal(value) => Ok(value),
            TextValue::Caught => self
                .caught
                .as_ref()
                .map(|error| error.message.clone())
                .ok_or(AsyncTrap::InvalidState),
        }
    }

    fn step(&mut self, id: TaskId, dom: &mut Node, events: &mut Vec<AsyncEvent>) -> Progress {
        if self.steps_left == 0 {
            return Self::trap(AsyncTrap::StepBudget);
        }
        self.steps_left -= 1;
        if let Some(resume) = self.resume.take() {
            return match resume {
                Ok(()) => Progress::Ready,
                Err(AsyncFailure::Exception(exception)) => self.raise(exception),
                Err(AsyncFailure::Trap(trap)) => Self::trap(trap),
            };
        }
        let Some(instruction) = self.program.code.get(self.pc).cloned() else {
            return Self::trap(AsyncTrap::InvalidState);
        };
        self.pc += 1;
        match instruction {
            Instruction::EnterTry { catch } => {
                if self.handler.is_some() || self.caught.is_some() {
                    return Self::trap(AsyncTrap::InvalidState);
                }
                self.handler = Some(catch);
            }
            Instruction::LeaveTry { end } => {
                if self.handler.take().is_none() {
                    return Self::trap(AsyncTrap::InvalidState);
                }
                self.pc = end;
            }
            Instruction::ClearCatch => self.caught = None,
            Instruction::AwaitFetch { method, url } => {
                let token = RequestToken {
                    task: id,
                    continuation: self.pc,
                };
                self.pending = Some(token);
                events.push(AsyncEvent::Request {
                    task: id,
                    token,
                    method,
                    url,
                });
                return Progress::Waiting;
            }
            Instruction::Throw(value) => {
                return match self.text(value) {
                    Ok(message) => self.raise(JsException {
                        kind: JsExceptionKind::Thrown,
                        message,
                    }),
                    Err(trap) => Self::trap(trap),
                };
            }
            Instruction::Log(value) => match self.text(value) {
                Ok(value) => events.push(AsyncEvent::Log { task: id, value }),
                Err(trap) => return Self::trap(trap),
            },
            Instruction::Dom(program) => {
                if let Err(message) = run_dom(&program, dom) {
                    return Self::trap(AsyncTrap::Dom(message));
                }
            }
            Instruction::Finish => return Progress::Finished(Ok(())),
        }
        Progress::Ready
    }
}

#[derive(Debug, Default)]
pub struct AsyncScheduler {
    limits: AsyncLimits,
    next_task: u64,
    tasks: BTreeMap<TaskId, Task>,
    ready: VecDeque<TaskId>,
}

impl AsyncScheduler {
    pub fn new(limits: AsyncLimits) -> Result<Self, AsyncLimit> {
        limits.validate()?;
        Ok(Self {
            limits,
            ..Self::default()
        })
    }

    pub fn limits(&self) -> AsyncLimits {
        self.limits
    }

    pub fn active_tasks(&self) -> usize {
        self.tasks.len()
    }

    pub fn ready_tasks(&self) -> usize {
        self.ready.len()
    }

    pub fn pending_tasks(&self) -> usize {
        self.tasks.len() - self.ready.len()
    }

    pub fn spawn(&mut self, program: AsyncProgram) -> Result<TaskId, AsyncSpawnError> {
        if self.tasks.len() >= self.limits.max_tasks {
            return Err(AsyncSpawnError::QueueFull);
        }
        if program.instruction_count() > self.limits.max_program_steps {
            return Err(AsyncSpawnError::ProgramLimit(AsyncLimit::ProgramSteps));
        }
        if program.text_bytes() > self.limits.max_program_text_bytes {
            return Err(AsyncSpawnError::ProgramLimit(AsyncLimit::ProgramTextBytes));
        }
        self.next_task = self
            .next_task
            .checked_add(1)
            .ok_or(AsyncSpawnError::IdExhausted)?;
        let id = TaskId(self.next_task);
        self.tasks.insert(
            id,
            Task {
                program,
                pc: 0,
                handler: None,
                caught: None,
                pending: None,
                resume: None,
                steps_left: self.limits.max_task_steps,
            },
        );
        self.ready.push_back(id);
        Ok(id)
    }

    pub fn complete(
        &mut self,
        token: RequestToken,
        result: Result<String, String>,
    ) -> CompletionStatus {
        let Some(task) = self.tasks.get_mut(&token.task) else {
            return CompletionStatus::Discarded;
        };
        if task.pending != Some(token) {
            return CompletionStatus::Discarded;
        }
        let bytes = match &result {
            Ok(value) | Err(value) => value.len(),
        };
        let status = if bytes > self.limits.max_response_bytes {
            task.resume = Some(Err(AsyncFailure::Trap(AsyncTrap::ResponseBudget)));
            CompletionStatus::LimitExceeded
        } else {
            task.resume = Some(result.map(|_| ()).map_err(|message| {
                AsyncFailure::Exception(JsException {
                    kind: JsExceptionKind::Rejected,
                    message,
                })
            }));
            CompletionStatus::Accepted
        };
        task.pending = None;
        self.ready.push_back(token.task);
        status
    }

    pub fn cancel(&mut self, id: TaskId) -> bool {
        let removed = self.tasks.remove(&id).is_some();
        if removed {
            self.ready.retain(|&task| task != id);
        }
        removed
    }

    pub fn cancel_all(&mut self) -> usize {
        let count = self.tasks.len();
        self.tasks.clear();
        self.ready.clear();
        count
    }

    pub fn tick(&mut self, dom: &mut Node) -> AsyncTick {
        let mut events = Vec::new();
        let mut steps = 0;
        while steps < self.limits.steps_per_tick {
            let Some(id) = self.ready.pop_front() else {
                break;
            };
            let Some(mut task) = self.tasks.remove(&id) else {
                events.push(AsyncEvent::Finished {
                    task: id,
                    result: Err(AsyncFailure::Trap(AsyncTrap::InvalidState)),
                });
                steps += 1;
                continue;
            };
            steps += 1;
            match task.step(id, dom, &mut events) {
                Progress::Ready => {
                    self.tasks.insert(id, task);
                    self.ready.push_back(id);
                }
                Progress::Waiting => {
                    self.tasks.insert(id, task);
                }
                Progress::Finished(result) => {
                    events.push(AsyncEvent::Finished { task: id, result })
                }
            }
        }
        AsyncTick {
            events,
            steps,
            ready: self.ready_tasks(),
            pending: self.pending_tasks(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dom() -> Node {
        let mut root = Node::elem("document");
        let mut status = Node::elem("p");
        status.set_attribute("id", "status").unwrap();
        root.append_child(status);
        root.clear_dirty();
        root
    }

    fn request(tick: &AsyncTick) -> RequestToken {
        tick.events
            .iter()
            .find_map(|event| match event {
                AsyncEvent::Request { token, .. } => Some(*token),
                _ => None,
            })
            .expect("request event")
    }

    fn logs(tick: &AsyncTick) -> Vec<&str> {
        tick.events
            .iter()
            .filter_map(|event| match event {
                AsyncEvent::Log { value, .. } => Some(value.as_str()),
                _ => None,
            })
            .collect()
    }

    fn finished(tick: &AsyncTick, task: TaskId, result: Result<(), AsyncFailure>) {
        assert!(
            tick.events.contains(&AsyncEvent::Finished { task, result }),
            "{tick:?}"
        );
    }

    #[test]
    fn fulfilled_await_yields_and_resumes_without_holding_dom() {
        let source = r#"
            try {
                document.getElementById('status').textContent = 'loading';
                await fetch('/bios/menu', {method: 'get'});
                document.getElementById('status').textContent = 'loaded';
                console.log('done');
            } catch (e) {
                console.log(e);
                document.getElementById('status').textContent = 'failed';
            }
        "#;
        assert!(crate::compile(source).is_err());
        let mut scheduler = AsyncScheduler::default();
        let task = scheduler.spawn(compile_async(source).unwrap()).unwrap();
        let mut dom = dom();
        let tick = scheduler.tick(&mut dom);
        let token = request(&tick);
        assert_eq!(token.task(), task);
        assert_eq!(
            tick.events,
            vec![AsyncEvent::Request {
                task,
                token,
                method: "GET".into(),
                url: "/bios/menu".into(),
            }]
        );
        assert_eq!((tick.steps, tick.ready, tick.pending), (3, 0, 1));
        assert_eq!(dom.inner_text(), "loading");
        for _ in 0..8 {
            let idle = scheduler.tick(&mut dom);
            assert_eq!((idle.steps, idle.ready, idle.pending), (0, 0, 1));
            assert!(idle.events.is_empty());
        }
        dom.get_element_by_id("status")
            .unwrap()
            .set_inner_text("painted while waiting");
        assert_eq!(
            scheduler.complete(token, Ok("response body".into())),
            CompletionStatus::Accepted
        );
        assert_eq!(dom.inner_text(), "painted while waiting");
        let tick = scheduler.tick(&mut dom);
        assert_eq!(logs(&tick), vec!["done"]);
        assert_eq!(dom.inner_text(), "loaded");
        finished(&tick, task, Ok(()));
        assert_eq!(scheduler.active_tasks(), 0);
    }

    #[test]
    fn rejected_await_runs_catch_and_skips_remaining_try() {
        let mut scheduler = AsyncScheduler::default();
        let task = scheduler
            .spawn(
                compile_async(
                    r#"
            try {
                await fetch('/bios/usb');
                console.log('not reached');
            } catch (reason) {
                console.log(reason);
                document.querySelector('#status').textContent = 'recovered';
            }
            console.log('after');
        "#,
                )
                .unwrap(),
            )
            .unwrap();
        let mut dom = dom();
        let token = request(&scheduler.tick(&mut dom));
        assert_eq!(
            scheduler.complete(token, Err("unplugged".into())),
            CompletionStatus::Accepted
        );
        let tick = scheduler.tick(&mut dom);
        assert_eq!(logs(&tick), vec!["unplugged", "after"]);
        assert_eq!(dom.inner_text(), "recovered");
        finished(&tick, task, Ok(()));
    }

    #[test]
    fn throws_catch_and_rethrow_do_not_reenter_handler() {
        let mut scheduler = AsyncScheduler::default();
        let task = scheduler
            .spawn(
                compile_async(
                    r#"
            try { throw 'first'; console.log('bad'); }
            catch (e) { console.log(e); throw e; console.log('bad'); }
            console.log('bad');
        "#,
                )
                .unwrap(),
            )
            .unwrap();
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["first"]);
        finished(
            &tick,
            task,
            Err(AsyncFailure::Exception(JsException {
                kind: JsExceptionKind::Thrown,
                message: "first".into(),
            })),
        );
        assert_eq!(scheduler.active_tasks(), 0);
    }

    #[test]
    fn uncaught_rejection_and_throw_have_typed_exception_kinds() {
        for (source, rejection, kind) in [
            (
                "await fetch('/bios/x'); console.log('bad');",
                true,
                JsExceptionKind::Rejected,
            ),
            (
                "throw 'failure'; console.log('bad');",
                false,
                JsExceptionKind::Thrown,
            ),
        ] {
            let mut scheduler = AsyncScheduler::default();
            let task = scheduler.spawn(compile_async(source).unwrap()).unwrap();
            let mut tick = scheduler.tick(&mut dom());
            if rejection {
                let token = request(&tick);
                scheduler.complete(token, Err("failure".into()));
                tick = scheduler.tick(&mut dom());
            }
            assert!(logs(&tick).is_empty());
            finished(
                &tick,
                task,
                Err(AsyncFailure::Exception(JsException {
                    kind,
                    message: "failure".into(),
                })),
            );
        }
    }

    #[test]
    fn catch_binding_survives_await_but_catch_rejection_is_not_recaught() {
        for reject in [false, true] {
            let mut scheduler = AsyncScheduler::default();
            let task = scheduler
                .spawn(
                    compile_async(
                        r#"
                try { throw 'original'; }
                catch (e) { await fetch('/bios/recover'); console.log(e); }
                try { throw 'second'; } catch (next) { console.log(next); }
            "#,
                    )
                    .unwrap(),
                )
                .unwrap();
            let token = request(&scheduler.tick(&mut dom()));
            scheduler.complete(
                token,
                if reject {
                    Err("recovery failed".into())
                } else {
                    Ok("ok".into())
                },
            );
            let tick = scheduler.tick(&mut dom());
            if reject {
                assert!(logs(&tick).is_empty());
                finished(
                    &tick,
                    task,
                    Err(AsyncFailure::Exception(JsException {
                        kind: JsExceptionKind::Rejected,
                        message: "recovery failed".into(),
                    })),
                );
            } else {
                assert_eq!(logs(&tick), vec!["original", "second"]);
                finished(&tick, task, Ok(()));
            }
        }
    }

    #[test]
    fn pending_does_not_block_other_tasks_and_ready_work_is_round_robin() {
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            steps_per_tick: 2,
            ..AsyncLimits::default()
        })
        .unwrap();
        let waiting = scheduler
            .spawn(compile_async("await fetch('/bios/wait');").unwrap())
            .unwrap();
        let first = scheduler
            .spawn(compile_async("console.log('a'); console.log('c');").unwrap())
            .unwrap();
        let second = scheduler
            .spawn(compile_async("console.log('b'); console.log('d');").unwrap())
            .unwrap();
        let tick = scheduler.tick(&mut dom());
        assert_eq!((tick.steps, tick.pending), (2, 1));
        assert_eq!(request(&tick).task(), waiting);
        assert_eq!(logs(&tick), vec!["a"]);
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["b", "c"]);
        assert_eq!(tick.steps, 2);
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["d"]);
        finished(&tick, first, Ok(()));
        let tick = scheduler.tick(&mut dom());
        finished(&tick, second, Ok(()));
        assert_eq!((tick.ready, tick.pending), (0, 1));
        assert_eq!(scheduler.tick(&mut dom()).steps, 0);
    }

    #[test]
    fn completions_are_one_shot_out_of_order_and_generation_checked() {
        let mut scheduler = AsyncScheduler::default();
        let first = scheduler
            .spawn(
                compile_async(
                    "await fetch('/bios/one'); await fetch('/bios/two'); console.log('first');",
                )
                .unwrap(),
            )
            .unwrap();
        let second = scheduler
            .spawn(compile_async("await fetch('/bios/three'); console.log('second');").unwrap())
            .unwrap();
        let tick = scheduler.tick(&mut dom());
        let tokens: Vec<_> = tick
            .events
            .iter()
            .filter_map(|event| match event {
                AsyncEvent::Request { token, .. } => Some(*token),
                _ => None,
            })
            .collect();
        assert_eq!(tokens.len(), 2);
        assert_eq!(
            scheduler.complete(tokens[1], Ok(String::new())),
            CompletionStatus::Accepted
        );
        assert_eq!(
            scheduler.complete(tokens[1], Err("duplicate".into())),
            CompletionStatus::Discarded
        );
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["second"]);
        finished(&tick, second, Ok(()));
        scheduler.complete(tokens[0], Ok(String::new()));
        let next = request(&scheduler.tick(&mut dom()));
        assert_ne!(next, tokens[0]);
        assert_eq!(
            scheduler.complete(tokens[0], Err("stale".into())),
            CompletionStatus::Discarded
        );
        assert_eq!(
            scheduler.complete(next, Ok(String::new())),
            CompletionStatus::Accepted
        );
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["first"]);
        finished(&tick, first, Ok(()));
    }

    #[test]
    fn cancellation_discards_pending_and_already_queued_completions() {
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_tasks: 1,
            ..AsyncLimits::default()
        })
        .unwrap();
        let program = compile_async(
            "try { await fetch('/bios/x'); console.log('bad'); } catch(e) {console.log('bad');}",
        )
        .unwrap();
        let mut previous = None;
        for complete_first in [false, true] {
            let task = scheduler.spawn(program.clone()).unwrap();
            if let Some(old) = previous {
                assert_ne!(task, old);
            }
            previous = Some(task);
            let token = request(&scheduler.tick(&mut dom()));
            if complete_first {
                assert_eq!(
                    scheduler.complete(token, Err("bad".into())),
                    CompletionStatus::Accepted
                );
            }
            assert!(scheduler.cancel(task));
            assert!(!scheduler.cancel(task));
            assert_eq!(
                scheduler.complete(token, Ok("late".into())),
                CompletionStatus::Discarded
            );
            let tick = scheduler.tick(&mut dom());
            assert_eq!((tick.steps, tick.ready, tick.pending), (0, 0, 0));
            assert!(tick.events.is_empty());
        }
        let task = scheduler.spawn(program).unwrap();
        assert_eq!(scheduler.cancel_all(), 1);
        assert_eq!(scheduler.cancel_all(), 0);
        assert!(!scheduler.cancel(task));
        assert_eq!(scheduler.tick(&mut dom()).steps, 0);
    }

    #[test]
    fn admission_and_configuration_budgets_fail_closed() {
        assert_eq!(
            AsyncScheduler::new(AsyncLimits {
                steps_per_tick: 0,
                ..AsyncLimits::default()
            })
            .unwrap_err(),
            AsyncLimit::TickSteps
        );
        assert_eq!(
            AsyncScheduler::new(AsyncLimits {
                max_tasks: usize::MAX,
                ..AsyncLimits::default()
            })
            .unwrap_err(),
            AsyncLimit::Tasks
        );
        assert_eq!(
            compile_async_with_limits(
                "",
                AsyncLimits {
                    max_response_bytes: 0,
                    ..AsyncLimits::default()
                }
            ),
            Err(AsyncCompileError::InvalidLimits(AsyncLimit::ResponseBytes))
        );
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_tasks: 1,
            ..AsyncLimits::default()
        })
        .unwrap();
        let program = compile_async("await fetch('/bios/x');").unwrap();
        scheduler.spawn(program.clone()).unwrap();
        let token = request(&scheduler.tick(&mut dom()));
        assert_eq!(
            scheduler.spawn(program.clone()),
            Err(AsyncSpawnError::QueueFull)
        );
        assert_eq!((scheduler.ready_tasks(), scheduler.pending_tasks()), (0, 1));
        assert!(scheduler.cancel(token.task()));
        assert!(scheduler.spawn(program.clone()).is_ok());
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_program_text_bytes: 1,
            ..AsyncLimits::default()
        })
        .unwrap();
        assert_eq!(
            scheduler.spawn(program.clone()),
            Err(AsyncSpawnError::ProgramLimit(AsyncLimit::ProgramTextBytes))
        );
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_program_steps: 1,
            ..AsyncLimits::default()
        })
        .unwrap();
        assert_eq!(
            scheduler.spawn(program.clone()),
            Err(AsyncSpawnError::ProgramLimit(AsyncLimit::ProgramSteps))
        );
        let mut scheduler = AsyncScheduler {
            next_task: u64::MAX,
            ..AsyncScheduler::default()
        };
        assert_eq!(scheduler.spawn(program), Err(AsyncSpawnError::IdExhausted));
        assert_eq!(scheduler.active_tasks(), 0);
    }

    #[test]
    fn source_program_and_utf8_text_budgets_include_unreachable_code() {
        assert_eq!(
            compile_async_with_limits(
                "console.log('x');",
                AsyncLimits {
                    max_source_bytes: 4,
                    ..AsyncLimits::default()
                }
            ),
            Err(AsyncCompileError::Limit(AsyncLimit::SourceBytes))
        );
        assert_eq!(
            compile_async_with_limits(
                "console.log('x');",
                AsyncLimits {
                    max_program_steps: 1,
                    ..AsyncLimits::default()
                }
            ),
            Err(AsyncCompileError::Limit(AsyncLimit::ProgramSteps))
        );
        assert_eq!(
            compile_async_with_limits(
                "console.log('é');",
                AsyncLimits {
                    max_program_text_bytes: 1,
                    ..AsyncLimits::default()
                }
            ),
            Err(AsyncCompileError::Limit(AsyncLimit::ProgramTextBytes))
        );
        let program = compile_async_with_limits(
            "console.log('é');",
            AsyncLimits {
                max_program_text_bytes: 2,
                ..AsyncLimits::default()
            },
        )
        .unwrap();
        assert_eq!(program.text_bytes(), 2);
        assert_eq!(program.instruction_count(), 2);
        assert_eq!(
            compile_async_with_limits(
                "throw 'x'; console.log('unreachable');",
                AsyncLimits {
                    max_program_text_bytes: 2,
                    ..AsyncLimits::default()
                }
            ),
            Err(AsyncCompileError::Limit(AsyncLimit::ProgramTextBytes))
        );
    }

    #[test]
    fn step_and_response_budgets_are_traps_not_catchable_exceptions() {
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_task_steps: 2,
            ..AsyncLimits::default()
        })
        .unwrap();
        let task = scheduler
            .spawn(compile_async("try {throw 'x';} catch(e) {console.log('bad');}").unwrap())
            .unwrap();
        let tick = scheduler.tick(&mut dom());
        assert!(logs(&tick).is_empty());
        finished(&tick, task, Err(AsyncFailure::Trap(AsyncTrap::StepBudget)));
        for result in [Ok("éé".into()), Err("éé".into())] {
            let mut scheduler = AsyncScheduler::new(AsyncLimits {
                max_response_bytes: 3,
                ..AsyncLimits::default()
            })
            .unwrap();
            let task = scheduler.spawn(compile_async("try {await fetch('/bios/x'); console.log('bad');} catch(e) {console.log('bad');}").unwrap()).unwrap();
            let token = request(&scheduler.tick(&mut dom()));
            assert_eq!(
                scheduler.complete(token, result),
                CompletionStatus::LimitExceeded
            );
            assert_eq!(
                scheduler.complete(token, Ok(String::new())),
                CompletionStatus::Discarded
            );
            let tick = scheduler.tick(&mut dom());
            assert!(logs(&tick).is_empty());
            finished(
                &tick,
                task,
                Err(AsyncFailure::Trap(AsyncTrap::ResponseBudget)),
            );
        }
        let mut scheduler = AsyncScheduler::new(AsyncLimits {
            max_response_bytes: 2,
            ..AsyncLimits::default()
        })
        .unwrap();
        let task = scheduler
            .spawn(
                compile_async("try {await fetch('/bios/x');} catch(e) {console.log(e);}").unwrap(),
            )
            .unwrap();
        let token = request(&scheduler.tick(&mut dom()));
        assert_eq!(
            scheduler.complete(token, Err("é".into())),
            CompletionStatus::Accepted
        );
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["é"]);
        finished(&tick, task, Ok(()));
    }

    #[test]
    fn dom_failures_are_host_traps_and_do_not_roll_back_prior_statements() {
        let mut scheduler = AsyncScheduler::default();
        let task = scheduler
            .spawn(
                compile_async(
                    r#"
            document.getElementById('status').textContent = 'committed';
            try { document.getElementById('absent').textContent = 'bad'; }
            catch(e) { console.log('not a modeled JS exception'); }
        "#,
                )
                .unwrap(),
            )
            .unwrap();
        let mut dom = dom();
        let tick = scheduler.tick(&mut dom);
        assert_eq!(dom.inner_text(), "committed");
        assert!(logs(&tick).is_empty());
        assert!(matches!(&tick.events[..], [AsyncEvent::Finished {
            task: id, result: Err(AsyncFailure::Trap(AsyncTrap::Dom(_))),
        }] if *id == task));
    }

    #[test]
    fn validates_all_source_before_admission_and_rejects_unsupported_nesting() {
        for source in [
            "try {try {} catch(e) {}} catch(e) {}",
            "try {} catch(e) {try {} catch(x) {}}",
            "try {} catch(e) {} finally {}",
            "try {await fetch('/bios/x');}",
            "try {} catch(await) {}",
            "try {} catch(console) {}",
            "try {} catch(e) { console.log(e + 'x'); }",
            "try {throw 'x';} catch(e) {} console.log(e);",
            "try {console.log(e);} catch(e) {}",
            "try {} catch(e) {e = 'other';}",
            "{ await fetch('/bios/x'); }",
            "fetch('/bios/x');",
            "await fetch('https://example.test/x');",
            r#"await fetch('/bios\\other');"#,
            r#"await fetch('/bios/\nother');"#,
            "await fetch('/bios/x', {method: 'TRACE'});",
            "await fetch('/bios/x', {headers: 'unsupported'});",
            "await Promise.resolve('x');",
            "await await fetch('/bios/x');",
            "var value = await fetch('/bios/x');",
            "async function f() {await fetch('/bios/x');}",
            "while (true) {await fetch('/bios/x');}",
            "throw\n'x';",
            "throw/*\n*/'x';",
            "document.getElementById('status').getContext('webgl');",
            "document.getElementById('status').appendChild(document.querySelector('#status'));",
            "document.getElementById('status').setAttribute('bad name', 'x');",
            "document.getElementById('status').innerHTML = 'x';",
            "console.log('x') console.log('y');",
            "console.log('unterminated);",
            "throw 'x'; unsupported();",
        ] {
            let prefixed = format!("document.getElementById('status').textContent = 'must not run'; console.log('must not log'); {source}");
            assert!(compile_async(&prefixed).is_err(), "{source}");
        }
        for source in [
            "await fetch('/bios/x');",
            "try { await fetch('/bios/x'); } catch(e) {console.log(e);}",
            "throw 'x';",
        ] {
            assert!(
                crate::compile(source).is_err(),
                "static compiler accepted {source}"
            );
        }
    }

    #[test]
    fn lexer_comments_escapes_and_statement_boundaries_are_shared() {
        let source = r#"
            /* await fetch('ignored'); try {} */
            try {
                await /* real suspension */ fetch('/bios/' + 'x')
                throw 'can\'t } catch(e) { \u03a9'
            } catch (error) {
                console.log(error)
                console.log('after')
            }
        "#;
        let mut scheduler = AsyncScheduler::default();
        let task = scheduler.spawn(compile_async(source).unwrap()).unwrap();
        let token = request(&scheduler.tick(&mut dom()));
        scheduler.complete(token, Ok(String::new()));
        let tick = scheduler.tick(&mut dom());
        assert_eq!(logs(&tick), vec!["can't } catch(e) { Ω", "after"]);
        finished(&tick, task, Ok(()));
    }

    #[test]
    fn short_malformed_token_streams_do_not_panic() {
        let atoms = [
            "", "try", "catch", "await", "throw", "fetch", "console", "{", "}", "(", ")", "'x'",
            ";", "\n", "/*", "Ω",
        ];
        for a in atoms {
            for b in atoms {
                for c in atoms {
                    let _ = compile_async(&format!("{a} {b} {c}"));
                }
            }
        }
    }
}
