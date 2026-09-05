// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use std::collections::HashMap;
use std::sync::Arc;

use g6b_holyc::{HandlerPoll, HandlerTask, Program};
use g6b_spec::BoardSpec;
use g6b_webidl::{WorkerError, WorkerErrorName};

use crate::tasks::{
    Dispatch, Job, Role, Scheduler, SchedulerConfig, TaskId, TaskInfo, TaskResult, TaskState,
};

pub struct TaskServices {
    scheduler: Scheduler,
    handlers: HashMap<TaskId, HandlerTask>,
    xlen: u32,
    stack_bytes: u32,
    worker_limit: usize,
}

pub struct Work {
    dispatch: Dispatch,
    job: Arc<Job>,
    handler: Option<HandlerTask>,
}

pub struct WorkResponse {
    dispatch: Dispatch,
    outcome: WorkOutcome,
}

enum WorkOutcome {
    Yielded(HandlerTask),
    Finished(Result<Vec<u8>, WorkerError>),
}

fn failure(name: WorkerErrorName, message: impl AsRef<str>) -> WorkerError {
    WorkerError::new(name, message)
}

fn scheduler_error(error: crate::tasks::SchedulerError) -> WorkerError {
    use crate::tasks::SchedulerError::*;
    let name = match error {
        TaskCapacity | ReadyCapacity | JobBytes | JobCapacity | ResultBytes | ResultCapacity => {
            WorkerErrorName::QuotaExceededError
        }
        TaskNotFound | StaleDispatch | InvalidState => WorkerErrorName::InvalidStateError,
        _ => WorkerErrorName::DataError,
    };
    failure(name, error.to_string())
}

impl TaskServices {
    pub fn new(spec: &BoardSpec) -> Result<Self, WorkerError> {
        spec.check()
            .map_err(|error| failure(WorkerErrorName::DataError, error))?;
        if !spec.kernel.tasking.enable {
            return Err(failure(
                WorkerErrorName::NotSupportedError,
                "task services disabled by BoardSpec",
            ));
        }
        let mut config = SchedulerConfig::new(
            spec.harts as usize,
            spec.threads as usize,
            spec.kernel.tasking.ui_hart as usize,
            spec.kernel.tasking.max_tasks as usize,
        )
        .map_err(scheduler_error)?;
        config.limits.max_job_bytes = 1_048_576;
        config.limits.max_total_job_bytes = 16_777_216;
        config.limits.max_result_bytes = 65_536;
        config.limits.max_total_result_bytes = config.capacity * config.limits.max_result_bytes;
        Ok(Self {
            scheduler: Scheduler::new(config).map_err(scheduler_error)?,
            handlers: HashMap::new(),
            xlen: spec.isa.xlen,
            stack_bytes: spec.kernel.tasking.stack_bytes,
            worker_limit: spec.worker_limit() as usize,
        })
    }

    pub fn thread_command(
        &mut self,
        program: &Program,
        command: &str,
    ) -> Result<TaskId, WorkerError> {
        let request = g6b_holyc::parse_thread_request(command)
            .map_err(|error| failure(WorkerErrorName::DataError, error))?;
        self.spawn_handler(program, &request.handler, request.argument)
    }

    pub fn spawn_handler(
        &mut self,
        program: &Program,
        name: &str,
        argument: u64,
    ) -> Result<TaskId, WorkerError> {
        let handler = program
            .prepare_handler(name, argument)
            .map_err(|error| failure(WorkerErrorName::DataError, error))?;
        let id = self
            .scheduler
            .spawn(
                Role::Main,
                Job::HolyC {
                    handler: name.into(),
                    arg: argument,
                },
            )
            .map_err(scheduler_error)?;
        self.handlers.insert(id, handler);
        Ok(id)
    }

    pub fn spawn_digest(&mut self, bytes: &[u8]) -> Result<TaskId, WorkerError> {
        let bytes =
            g6b_webidl::clone_worker_buffer(bytes, self.scheduler.config().limits.max_job_bytes)?;
        self.scheduler
            .spawn(Role::Worker, Job::Sha256 { bytes })
            .map_err(scheduler_error)
    }

    pub fn spawn_wasm(
        &mut self,
        module: &[u8],
        export: &str,
        args: &[i32],
    ) -> Result<TaskId, WorkerError> {
        if module.len() > 1_048_000 || args.len() > 32 || export.len() > 256 {
            return Err(failure(
                WorkerErrorName::QuotaExceededError,
                "WASM worker input budget exceeded",
            ));
        }
        let decoded =
            g6b_wasm::decode(module).map_err(|error| failure(WorkerErrorName::DataError, error))?;
        if !decoded.imports.is_empty()
            || !decoded
                .exports
                .iter()
                .any(|item| item.kind == 0 && item.name == export)
        {
            return Err(failure(
                WorkerErrorName::NotSupportedError,
                "numeric worker requires a function export and no host imports",
            ));
        }
        self.scheduler
            .spawn(
                Role::Worker,
                Job::WasmNumeric {
                    module: module.to_vec(),
                    export: export.into(),
                    args: args.iter().map(|&value| i64::from(value)).collect(),
                },
            )
            .map_err(scheduler_error)
    }

    pub fn dispatch(&mut self, hart: usize) -> Result<Option<Work>, WorkerError> {
        if self.scheduler.counters().running >= self.worker_limit {
            return Ok(None);
        }
        let Some(dispatch) = self.scheduler.dispatch(hart).map_err(scheduler_error)? else {
            return Ok(None);
        };
        let job = self.scheduler.job(dispatch).map_err(scheduler_error)?;
        let handler = self.handlers.remove(&dispatch.task());
        Ok(Some(Work {
            dispatch,
            job,
            handler,
        }))
    }

    pub fn accept(&mut self, response: WorkResponse) -> Result<TaskState, WorkerError> {
        self.scheduler
            .job(response.dispatch)
            .map_err(scheduler_error)?;
        match response.outcome {
            WorkOutcome::Yielded(handler) => {
                let state = self
                    .scheduler
                    .yield_now(response.dispatch)
                    .map_err(scheduler_error)?;
                if state == TaskState::Ready {
                    self.handlers.insert(response.dispatch.task(), handler);
                }
                Ok(state)
            }
            WorkOutcome::Finished(result) => {
                let result = match result {
                    Ok(bytes) if bytes.len() < self.scheduler.config().limits.max_result_bytes => {
                        let mut encoded = vec![0];
                        encoded.extend(bytes);
                        encoded
                    }
                    result => {
                        let error = result.err().unwrap_or_else(|| {
                            failure(
                                WorkerErrorName::QuotaExceededError,
                                "worker result budget exceeded",
                            )
                        });
                        let mut encoded = vec![1];
                        encoded.extend_from_slice(error.name.as_str().as_bytes());
                        encoded.push(0);
                        encoded.extend_from_slice(error.message.as_bytes());
                        encoded
                    }
                };
                self.scheduler
                    .complete(response.dispatch, result)
                    .map_err(scheduler_error)
            }
        }
    }

    pub fn take_result(
        &mut self,
        id: TaskId,
    ) -> Result<Option<Result<Vec<u8>, WorkerError>>, WorkerError> {
        let result = self.scheduler.take_result(id).map_err(scheduler_error)?;
        Ok(result.map(|result| match result {
            TaskResult::Cancelled => Err(failure(WorkerErrorName::AbortError, "task cancelled")),
            TaskResult::Completed(mut bytes) if bytes.first() == Some(&0) => {
                bytes.remove(0);
                Ok(bytes)
            }
            TaskResult::Completed(bytes) => {
                let text = String::from_utf8_lossy(bytes.get(1..).unwrap_or_default());
                let (name, message) = text.split_once('\0').unwrap_or(("OperationError", &text));
                let name = match name {
                    "AbortError" => WorkerErrorName::AbortError,
                    "DataCloneError" => WorkerErrorName::DataCloneError,
                    "DataError" => WorkerErrorName::DataError,
                    "InvalidStateError" => WorkerErrorName::InvalidStateError,
                    "NotSupportedError" => WorkerErrorName::NotSupportedError,
                    "QuotaExceededError" => WorkerErrorName::QuotaExceededError,
                    _ => WorkerErrorName::OperationError,
                };
                Err(failure(name, message))
            }
        }))
    }

    pub fn cancel(&mut self, id: TaskId) -> Result<TaskState, WorkerError> {
        let state = self.scheduler.cancel(id).map_err(scheduler_error)?;
        if state != TaskState::Running {
            self.handlers.remove(&id);
        }
        Ok(state)
    }

    pub fn task(&self, id: TaskId) -> Result<TaskInfo, WorkerError> {
        self.scheduler.task(id).map_err(scheduler_error)
    }
    pub fn counters(&self) -> crate::tasks::Counters {
        self.scheduler.counters()
    }
    pub fn worker_harts(&self) -> Vec<usize> {
        self.scheduler.config().worker_harts().unwrap_or_default()
    }

    pub fn native_primitives(&self) -> Result<g6b_asm::Module, String> {
        let mut module = g6b_asm::task::task_switch_ir(self.xlen)?;
        module
            .nodes
            .extend(g6b_asm::task::task_entry_ir(self.xlen)?.nodes);
        module.nharts = self.scheduler.config().hart_count as u32;
        Ok(module)
    }

    pub fn initial_context(
        &self,
        id: TaskId,
        address: u64,
        start: g6b_asm::task::TaskStart,
    ) -> Result<Vec<u8>, WorkerError> {
        let info = self.task(id)?;
        if start.hart_id != info.hart as u64
            || start.stack_bytes != u64::from(self.stack_bytes)
            || info.state != TaskState::Ready
        {
            return Err(failure(
                WorkerErrorName::InvalidStateError,
                "context owner, stack size or task state mismatch",
            ));
        }
        g6b_asm::task::TaskLayout::new(self.xlen)
            .and_then(|layout| layout.initial_context(address, start))
            .map_err(|error| failure(WorkerErrorName::DataError, error))
    }
}

impl Work {
    pub fn task(&self) -> TaskId {
        self.dispatch.task()
    }
    pub fn hart(&self) -> usize {
        self.dispatch.hart()
    }

    pub fn native_wasm_ir(&self, xlen: u32) -> Result<g6b_asm::Module, String> {
        let Job::WasmNumeric { module, export, .. } = &*self.job else {
            return Err("not a numeric WASM job".into());
        };
        g6b_wasm::jit_riscv(&g6b_wasm::decode(module)?, export, xlen)
    }

    pub fn abort(self) -> WorkResponse {
        WorkResponse {
            dispatch: self.dispatch,
            outcome: WorkOutcome::Finished(Err(failure(
                WorkerErrorName::AbortError,
                "work cancelled before execution",
            ))),
        }
    }

    pub fn run(mut self) -> WorkResponse {
        let outcome = match &*self.job {
            Job::HolyC { .. } => match self.handler.take() {
                Some(mut handler) => match handler.poll(64) {
                    HandlerPoll::Yielded => WorkOutcome::Yielded(handler),
                    HandlerPoll::Finished(result) => WorkOutcome::Finished(
                        result
                            .map(String::into_bytes)
                            .map_err(|error| failure(WorkerErrorName::OperationError, error)),
                    ),
                },
                None => WorkOutcome::Finished(Err(failure(
                    WorkerErrorName::InvalidStateError,
                    "handler continuation missing",
                ))),
            },
            Job::Sha256 { bytes } => WorkOutcome::Finished(Ok(g6b_tls::sha256(bytes).to_vec())),
            Job::WasmNumeric {
                module,
                export,
                args,
            } => WorkOutcome::Finished(run_numeric(module, export, args)),
            _ => WorkOutcome::Finished(Err(failure(
                WorkerErrorName::NotSupportedError,
                "UI/control tasks are not compute jobs",
            ))),
        };
        WorkResponse {
            dispatch: self.dispatch,
            outcome,
        }
    }
}

fn run_numeric(bytes: &[u8], export: &str, args: &[i64]) -> Result<Vec<u8>, WorkerError> {
    struct IsolatedHost;
    impl g6b_wasm::Host for IsolatedHost {
        fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
            Err("worker has no document".into())
        }
        fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
            Err("worker has no document".into())
        }
        fn log(&mut self, _: &str) {}
    }
    let execute = || -> Result<Vec<u8>, String> {
        let module = g6b_wasm::decode(bytes)?;
        if !module.imports.is_empty() {
            return Err("worker host imports are unavailable".into());
        }
        let index = module
            .exports
            .iter()
            .find(|item| item.kind == 0 && item.name == export)
            .ok_or("worker export missing")?
            .idx;
        let args = args
            .iter()
            .map(|&value| {
                i32::try_from(value).map_err(|_| "worker argument is not i32".to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let result = g6b_wasm::run_with_fuel(&module, index, &args, &mut IsolatedHost, 16_384)?;
        Ok(result.into_iter().flat_map(i32::to_le_bytes).collect())
    };
    execute().map_err(|error| failure(WorkerErrorName::OperationError, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> BoardSpec {
        BoardSpec::from_json_str(r#"{"schema_version":1,"harts":{"cores":4,"threads":2},"kernel":{"tasking":{"enable":true}}}"#).unwrap()
    }

    #[test]
    fn holyc_thread_creation_yields_and_reports_actual_handle_result() {
        let mut services = TaskServices::new(&spec()).unwrap();
        let program =
            Program::parse("U0 Compute(U64 value) { Print(value); Yield(); Print(\" done\"); }")
                .unwrap();
        let id = services
            .thread_command(&program, "ThreadCreate(\"Compute\", 42);")
            .unwrap();
        let hart = services.task(id).unwrap().hart;
        assert_ne!(hart, 0);
        let work = services.dispatch(hart).unwrap().unwrap();
        assert_eq!(services.accept(work.run()).unwrap(), TaskState::Ready);
        assert!(services.take_result(id).unwrap().is_none());
        let work = services.dispatch(hart).unwrap().unwrap();
        assert_eq!(services.accept(work.run()).unwrap(), TaskState::Finished);
        assert_eq!(
            services.take_result(id).unwrap().unwrap().unwrap(),
            b"42 done"
        );
        assert!(services.take_result(id).is_err());
        assert!(services
            .thread_command(&program, "ThreadCreate(\"Reboot\", 0);")
            .is_err());
    }

    #[test]
    fn owned_digest_jobs_can_run_on_host_threads_without_borrowing_the_ui() {
        let mut services = TaskServices::new(&spec()).unwrap();
        let ids: Vec<_> = (0..7)
            .map(|_| services.spawn_digest(b"abc").unwrap())
            .collect();
        let works: Vec<_> = services
            .worker_harts()
            .into_iter()
            .filter_map(|hart| services.dispatch(hart).unwrap())
            .collect();
        assert_eq!(works.len(), 7);
        assert!(works.iter().all(|work| work.hart() != 0));
        let threads: Vec<_> = works
            .into_iter()
            .map(|work| std::thread::spawn(move || work.run()))
            .collect();
        assert_eq!(services.counters().running, 7);
        for thread in threads {
            services.accept(thread.join().unwrap()).unwrap();
        }
        for id in ids {
            assert_eq!(
                services.take_result(id).unwrap().unwrap().unwrap(),
                g6b_tls::sha256(b"abc")
            );
        }
    }

    #[test]
    fn cancellation_discards_owned_work_and_holyc_throw_becomes_a_failure() {
        let mut services = TaskServices::new(&spec()).unwrap();
        let id = services.spawn_digest(b"abc").unwrap();
        let work = services
            .dispatch(services.task(id).unwrap().hart)
            .unwrap()
            .unwrap();
        assert_eq!(services.cancel(id).unwrap(), TaskState::Running);
        assert_eq!(services.accept(work.run()).unwrap(), TaskState::Cancelled);
        assert_eq!(
            services.take_result(id).unwrap().unwrap().unwrap_err().name,
            WorkerErrorName::AbortError
        );
        let program = Program::parse("U0 Bad() { Throw(\"failure\"); }").unwrap();
        let id = services.spawn_handler(&program, "Bad", 0).unwrap();
        let work = services
            .dispatch(services.task(id).unwrap().hart)
            .unwrap()
            .unwrap();
        services.accept(work.run()).unwrap();
        assert_eq!(
            services.take_result(id).unwrap().unwrap().unwrap_err().name,
            WorkerErrorName::OperationError
        );
    }

    #[test]
    fn wasm_worker_is_isolated_budgeted_and_has_native_jit_ir() {
        let bytes = b"\0asm\x01\0\0\0\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f\x03\x02\x01\0\x07\x07\x01\x03add\0\0\x0a\x09\x01\x07\0\x20\0\x20\x01\x6a\x0b";
        let mut services = TaskServices::new(&spec()).unwrap();
        let id = services.spawn_wasm(bytes, "add", &[7, 5]).unwrap();
        let work = services
            .dispatch(services.task(id).unwrap().hart)
            .unwrap()
            .unwrap();
        for xlen in [32, 64] {
            assert!(work.native_wasm_ir(xlen).unwrap().to_words(0).is_ok());
        }
        services.accept(work.run()).unwrap();
        assert_eq!(
            services.take_result(id).unwrap().unwrap().unwrap(),
            12i32.to_le_bytes()
        );
        let id = services.spawn_wasm(bytes, "add", &[7]).unwrap();
        let work = services
            .dispatch(services.task(id).unwrap().hart)
            .unwrap()
            .unwrap();
        services.accept(work.run()).unwrap();
        assert_eq!(
            services.take_result(id).unwrap().unwrap().unwrap_err().name,
            WorkerErrorName::OperationError
        );
        assert!(services.spawn_wasm(bytes, "missing", &[]).is_err());
    }

    #[test]
    fn contexts_and_native_ir_use_the_same_pinned_task_contract() {
        let mut services = TaskServices::new(&spec()).unwrap();
        let id = services.spawn_digest(b"abc").unwrap();
        let hart = services.task(id).unwrap().hart as u64;
        let mut start = g6b_asm::task::TaskStart {
            hart_id: hart,
            stack_base: 0x40000,
            stack_bytes: 32768,
            entry_pc: 0x1000,
            handler_pc: 0x2000,
            argument: 42,
            exit_pc: 0x3000,
            enable_interrupts: true,
        };
        assert_eq!(
            services.initial_context(id, 0x10000, start).unwrap().len(),
            128
        );
        start.hart_id = 0;
        assert!(services.initial_context(id, 0x10000, start).is_err());
        let ir = services.native_primitives().unwrap();
        assert!(ir.to_asm().contains("g6b_task_switch"));
        assert!(ir.to_words(0).is_ok());
        assert!(TaskServices::new(&BoardSpec::default()).is_err());
        assert!(services
            .spawn_wasm(g6b_wasm::bios_ui_wasm(), "_start", &[])
            .is_err());
    }
}
