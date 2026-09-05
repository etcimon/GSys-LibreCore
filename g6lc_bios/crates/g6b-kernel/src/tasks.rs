// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use std::collections::VecDeque;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub const MAX_HARTS: usize = 256;
pub const MAX_TASKS: usize = 4096;
pub const MAX_JOB_BYTES: usize = 1_048_576;
pub const MAX_RESULT_BYTES: usize = 1_048_576;
pub const MAX_BUFFERED_BYTES: usize = 16_777_216;

static NEXT_SCHEDULER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchedulerError {
    InvalidTopology,
    InvalidCapacity,
    InvalidLimits,
    InvalidRole,
    InvalidName,
    HartOutOfRange,
    TaskNotFound,
    StaleDispatch,
    InvalidState,
    TaskCapacity,
    ReadyCapacity,
    JobBytes,
    JobCapacity,
    NameBytes,
    WasmArgs,
    ResultBytes,
    ResultCapacity,
    ClockWentBackwards,
    TokenExhausted,
}

impl fmt::Display for SchedulerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "scheduler {:?}", self)
    }
}

impl std::error::Error for SchedulerError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SchedulerLimits {
    pub queue_capacity_per_hart: usize,
    pub max_job_bytes: usize,
    pub max_total_job_bytes: usize,
    pub max_name_bytes: usize,
    pub max_wasm_args: usize,
    pub max_result_bytes: usize,
    pub max_total_result_bytes: usize,
}

impl Default for SchedulerLimits {
    fn default() -> Self {
        Self {
            queue_capacity_per_hart: 64,
            max_job_bytes: 65_536,
            max_total_job_bytes: 1_048_576,
            max_name_bytes: 256,
            max_wasm_args: 64,
            max_result_bytes: 16_384,
            max_total_result_bytes: 262_144,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SchedulerConfig {
    pub hart_count: usize,
    pub threads_per_core: usize,
    pub ui_hart: usize,
    pub capacity: usize,
    pub limits: SchedulerLimits,
}

impl SchedulerConfig {
    pub fn new(
        hart_count: usize,
        threads_per_core: usize,
        ui_hart: usize,
        capacity: usize,
    ) -> Result<Self, SchedulerError> {
        let config = Self {
            hart_count,
            threads_per_core,
            ui_hart,
            capacity,
            limits: SchedulerLimits {
                queue_capacity_per_hart: capacity,
                ..SchedulerLimits::default()
            },
        };
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), SchedulerError> {
        if self.hart_count == 0
            || self.hart_count > MAX_HARTS
            || self.threads_per_core == 0
            || self.threads_per_core > self.hart_count
            || self.hart_count % self.threads_per_core != 0
            || self.ui_hart >= self.hart_count
        {
            return Err(SchedulerError::InvalidTopology);
        }
        if self.capacity == 0 || self.capacity > MAX_TASKS {
            return Err(SchedulerError::InvalidCapacity);
        }
        let limits = self.limits;
        if limits.queue_capacity_per_hart == 0
            || limits.queue_capacity_per_hart > self.capacity
            || limits.max_job_bytes == 0
            || limits.max_job_bytes > MAX_JOB_BYTES
            || limits.max_total_job_bytes < limits.max_job_bytes
            || limits.max_total_job_bytes > MAX_BUFFERED_BYTES
            || limits.max_name_bytes == 0
            || limits.max_name_bytes > 4096
            || limits.max_wasm_args > 1024
            || limits.max_result_bytes > MAX_RESULT_BYTES
            || limits.max_total_result_bytes < limits.max_result_bytes
            || limits.max_total_result_bytes > MAX_BUFFERED_BYTES
        {
            return Err(SchedulerError::InvalidLimits);
        }
        Ok(())
    }

    pub fn core_of(&self, hart: usize) -> Result<usize, SchedulerError> {
        self.validate()?;
        if hart >= self.hart_count {
            return Err(SchedulerError::HartOutOfRange);
        }
        Ok(hart / self.threads_per_core)
    }

    pub fn worker_harts(&self) -> Result<Vec<usize>, SchedulerError> {
        self.validate()?;
        if self.hart_count == 1 {
            return Ok(vec![self.ui_hart]);
        }
        let ui_core = self.ui_hart / self.threads_per_core;
        let core_count = self.hart_count / self.threads_per_core;
        let mut harts = Vec::with_capacity(self.hart_count - 1);
        for thread in 0..self.threads_per_core {
            for core in 0..core_count {
                if core != ui_core {
                    harts.push(core * self.threads_per_core + thread);
                }
            }
        }
        for thread in 0..self.threads_per_core {
            let hart = ui_core * self.threads_per_core + thread;
            if hart != self.ui_hart {
                harts.push(hart);
            }
        }
        Ok(harts)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Ui,
    Main,
    Worker,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Job {
    Ui,
    Main,
    HolyC {
        handler: String,
        arg: u64,
    },
    Sha256 {
        bytes: Vec<u8>,
    },
    WasmNumeric {
        module: Vec<u8>,
        export: String,
        args: Vec<i64>,
    },
}

impl Job {
    fn checked_bytes(&self, role: Role, limits: SchedulerLimits) -> Result<usize, SchedulerError> {
        let bytes = match self {
            Self::Ui if role == Role::Ui => 0,
            Self::Main if role == Role::Main => 0,
            Self::HolyC { handler, .. } => {
                Self::check_name(handler, limits)?;
                if !handler.bytes().enumerate().all(|(index, byte)| {
                    byte == b'_'
                        || byte.is_ascii_alphabetic()
                        || (index != 0 && byte.is_ascii_digit())
                }) {
                    return Err(SchedulerError::InvalidName);
                }
                handler
                    .len()
                    .checked_add(8)
                    .ok_or(SchedulerError::JobBytes)?
            }
            Self::Sha256 { bytes } if role == Role::Worker => bytes.len(),
            Self::WasmNumeric {
                module,
                export,
                args,
            } if role == Role::Worker => {
                Self::check_name(export, limits)?;
                if args.len() > limits.max_wasm_args {
                    return Err(SchedulerError::WasmArgs);
                }
                module
                    .len()
                    .checked_add(export.len())
                    .and_then(|bytes| bytes.checked_add(args.len().checked_mul(8)?))
                    .ok_or(SchedulerError::JobBytes)?
            }
            _ => return Err(SchedulerError::InvalidRole),
        };
        if bytes > limits.max_job_bytes {
            return Err(SchedulerError::JobBytes);
        }
        Ok(bytes)
    }

    fn check_name(name: &str, limits: SchedulerLimits) -> Result<(), SchedulerError> {
        if name.len() > limits.max_name_bytes {
            return Err(SchedulerError::NameBytes);
        }
        if name.is_empty() || name.bytes().any(|byte| byte == 0) {
            return Err(SchedulerError::InvalidName);
        }
        Ok(())
    }

    fn compact(self) -> Self {
        match self {
            Self::HolyC { handler, arg } => Self::HolyC {
                handler: handler.into_boxed_str().into_string(),
                arg,
            },
            Self::Sha256 { bytes } => Self::Sha256 {
                bytes: bytes.into_boxed_slice().into_vec(),
            },
            Self::WasmNumeric {
                module,
                export,
                args,
            } => Self::WasmNumeric {
                module: module.into_boxed_slice().into_vec(),
                export: export.into_boxed_str().into_string(),
                args: args.into_boxed_slice().into_vec(),
            },
            control => control,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TaskId {
    scheduler: u64,
    slot: usize,
    generation: u64,
}

impl TaskId {
    pub fn slot(self) -> usize {
        self.slot
    }

    pub fn generation(self) -> u64 {
        self.generation
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Dispatch {
    task: TaskId,
    hart: usize,
    epoch: u64,
}

impl Dispatch {
    pub fn task(self) -> TaskId {
        self.task
    }

    pub fn hart(self) -> usize {
        self.hart
    }

    pub fn epoch(self) -> u64 {
        self.epoch
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskState {
    Ready,
    Running,
    Blocked,
    Finished,
    Cancelled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TaskInfo {
    pub id: TaskId,
    pub role: Role,
    pub hart: usize,
    pub state: TaskState,
    pub cancel_requested: bool,
    pub wake_at: Option<u64>,
    pub dispatches: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TaskResult {
    Completed(Vec<u8>),
    Cancelled,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    pub resident: usize,
    pub ready: usize,
    pub running: usize,
    pub blocked: usize,
    pub finished: usize,
    pub cancelled: usize,
    pub cancellation_pending: usize,
    pub job_bytes: usize,
    pub result_bytes: usize,
    pub spawned_total: u64,
    pub dispatched_total: u64,
    pub yielded_total: u64,
    pub blocked_total: u64,
    pub woken_total: u64,
    pub completed_total: u64,
    pub cancelled_total: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HartCounters {
    pub ready: usize,
    pub running: usize,
    pub reserved_ready_slots: usize,
    pub dispatched_total: u64,
}

struct Task {
    info: TaskInfo,
    job: Option<Arc<Job>>,
    job_bytes: usize,
    result: Option<TaskResult>,
}

struct Slot {
    generation: u64,
    task: Option<Task>,
}

struct Hart {
    ready: VecDeque<TaskId>,
    running: Option<Dispatch>,
    dispatched_total: u64,
}

pub struct Scheduler {
    config: SchedulerConfig,
    identity: u64,
    slots: Vec<Slot>,
    harts: Vec<Hart>,
    worker_harts: Vec<usize>,
    placement_cursor: usize,
    epoch: u64,
    now: u64,
    totals: Counters,
}

impl Scheduler {
    pub fn new(config: SchedulerConfig) -> Result<Self, SchedulerError> {
        config.validate()?;
        let identity = NEXT_SCHEDULER
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .map_err(|_| SchedulerError::TokenExhausted)?;
        Ok(Self {
            config,
            identity,
            slots: (0..config.capacity)
                .map(|_| Slot {
                    generation: 0,
                    task: None,
                })
                .collect(),
            harts: (0..config.hart_count)
                .map(|_| Hart {
                    ready: VecDeque::with_capacity(config.limits.queue_capacity_per_hart),
                    running: None,
                    dispatched_total: 0,
                })
                .collect(),
            worker_harts: config.worker_harts()?,
            placement_cursor: 0,
            epoch: 0,
            now: 0,
            totals: Counters::default(),
        })
    }

    pub fn config(&self) -> SchedulerConfig {
        self.config
    }

    pub fn now(&self) -> u64 {
        self.now
    }

    pub fn spawn(&mut self, role: Role, job: Job) -> Result<TaskId, SchedulerError> {
        let job_bytes = job.checked_bytes(role, self.config.limits)?;
        if job_bytes > self.config.limits.max_total_job_bytes - self.totals.job_bytes {
            return Err(SchedulerError::JobCapacity);
        }
        let slot = self
            .slots
            .iter()
            .position(|slot| slot.task.is_none() && slot.generation < u64::MAX)
            .ok_or(SchedulerError::TaskCapacity)?;
        let hart = self.choose_hart(role)?;
        let generation = self.slots[slot].generation + 1;
        let id = TaskId {
            scheduler: self.identity,
            slot,
            generation,
        };
        self.slots[slot] = Slot {
            generation,
            task: Some(Task {
                info: TaskInfo {
                    id,
                    role,
                    hart,
                    state: TaskState::Ready,
                    cancel_requested: false,
                    wake_at: None,
                    dispatches: 0,
                },
                job: Some(Arc::new(job.compact())),
                job_bytes,
                result: None,
            }),
        };
        self.harts[hart].ready.push_back(id);
        if role != Role::Ui {
            self.placement_cursor = (self
                .worker_harts
                .iter()
                .position(|candidate| *candidate == hart)
                .unwrap()
                + 1)
                % self.worker_harts.len();
        }
        self.totals.job_bytes += job_bytes;
        self.totals.spawned_total = self.totals.spawned_total.saturating_add(1);
        Ok(id)
    }

    pub fn dispatch(&mut self, hart: usize) -> Result<Option<Dispatch>, SchedulerError> {
        let state = self.harts.get(hart).ok_or(SchedulerError::HartOutOfRange)?;
        if state.running.is_some() || state.ready.is_empty() {
            return Ok(None);
        }
        let epoch = self
            .epoch
            .checked_add(1)
            .ok_or(SchedulerError::TokenExhausted)?;
        let task = self.harts[hart].ready.pop_front().unwrap();
        let dispatch = Dispatch { task, hart, epoch };
        self.epoch = epoch;
        self.harts[hart].running = Some(dispatch);
        self.harts[hart].dispatched_total = self.harts[hart].dispatched_total.saturating_add(1);
        let info = &mut self.slots[task.slot].task.as_mut().unwrap().info;
        info.state = TaskState::Running;
        info.dispatches = info.dispatches.saturating_add(1);
        self.totals.dispatched_total = self.totals.dispatched_total.saturating_add(1);
        Ok(Some(dispatch))
    }

    pub fn job(&self, dispatch: Dispatch) -> Result<Arc<Job>, SchedulerError> {
        let index = self.validate_dispatch(dispatch)?;
        Ok(Arc::clone(
            self.slots[index]
                .task
                .as_ref()
                .unwrap()
                .job
                .as_ref()
                .unwrap(),
        ))
    }

    pub fn task(&self, id: TaskId) -> Result<TaskInfo, SchedulerError> {
        Ok(self.get_task(id)?.info)
    }

    pub fn yield_now(&mut self, dispatch: Dispatch) -> Result<TaskState, SchedulerError> {
        self.safe_point(dispatch, TaskState::Ready, None)
    }

    pub fn block(&mut self, dispatch: Dispatch) -> Result<TaskState, SchedulerError> {
        self.safe_point(dispatch, TaskState::Blocked, None)
    }

    pub fn sleep(&mut self, dispatch: Dispatch, wake_at: u64) -> Result<TaskState, SchedulerError> {
        if wake_at <= self.now {
            self.yield_now(dispatch)
        } else {
            self.safe_point(dispatch, TaskState::Blocked, Some(wake_at))
        }
    }

    pub fn wake(&mut self, id: TaskId) -> Result<(), SchedulerError> {
        let info = self.get_task(id)?.info;
        if info.state != TaskState::Blocked {
            return Err(SchedulerError::InvalidState);
        }
        if self.runnable_load(info.hart) >= self.config.limits.queue_capacity_per_hart {
            return Err(SchedulerError::ReadyCapacity);
        }
        let task = self.slots[id.slot].task.as_mut().unwrap();
        task.info.state = TaskState::Ready;
        task.info.wake_at = None;
        self.harts[info.hart].ready.push_back(id);
        self.totals.woken_total = self.totals.woken_total.saturating_add(1);
        Ok(())
    }

    pub fn advance_time(&mut self, now: u64) -> Result<usize, SchedulerError> {
        if now < self.now {
            return Err(SchedulerError::ClockWentBackwards);
        }
        self.now = now;
        let mut woken = 0;
        for index in 0..self.slots.len() {
            let due = self.slots[index].task.as_ref().and_then(|task| {
                if task.info.state == TaskState::Blocked
                    && task.info.wake_at.is_some_and(|deadline| deadline <= now)
                {
                    Some(task.info.id)
                } else {
                    None
                }
            });
            if let Some(id) = due {
                match self.wake(id) {
                    Ok(()) => woken += 1,
                    Err(SchedulerError::ReadyCapacity) => {}
                    Err(error) => return Err(error),
                }
            }
        }
        Ok(woken)
    }

    pub fn complete(
        &mut self,
        dispatch: Dispatch,
        result: Vec<u8>,
    ) -> Result<TaskState, SchedulerError> {
        let index = self.validate_dispatch(dispatch)?;
        if self.slots[index]
            .task
            .as_ref()
            .unwrap()
            .info
            .cancel_requested
        {
            self.finish(index, TaskResult::Cancelled);
            return Ok(TaskState::Cancelled);
        }
        if result.len() > self.config.limits.max_result_bytes {
            return Err(SchedulerError::ResultBytes);
        }
        if result.len() > self.config.limits.max_total_result_bytes - self.totals.result_bytes {
            return Err(SchedulerError::ResultCapacity);
        }
        self.finish(
            index,
            TaskResult::Completed(result.into_boxed_slice().into_vec()),
        );
        Ok(TaskState::Finished)
    }

    pub fn cancel(&mut self, id: TaskId) -> Result<TaskState, SchedulerError> {
        let info = self.get_task(id)?.info;
        match info.state {
            TaskState::Finished | TaskState::Cancelled => return Ok(info.state),
            TaskState::Running => {
                self.slots[id.slot]
                    .task
                    .as_mut()
                    .unwrap()
                    .info
                    .cancel_requested = true;
                return Ok(TaskState::Running);
            }
            TaskState::Ready => self.harts[info.hart].ready.retain(|queued| *queued != id),
            TaskState::Blocked => {}
        }
        self.slots[id.slot]
            .task
            .as_mut()
            .unwrap()
            .info
            .cancel_requested = true;
        self.finish(id.slot, TaskResult::Cancelled);
        Ok(TaskState::Cancelled)
    }

    pub fn take_result(&mut self, id: TaskId) -> Result<Option<TaskResult>, SchedulerError> {
        let task = self.get_task(id)?;
        if !matches!(task.info.state, TaskState::Finished | TaskState::Cancelled) {
            return Ok(None);
        }
        let task = self.slots[id.slot].task.take().unwrap();
        let result = task.result.unwrap();
        if let TaskResult::Completed(bytes) = &result {
            self.totals.result_bytes -= bytes.len();
        }
        Ok(Some(result))
    }

    pub fn counters(&self) -> Counters {
        let mut counters = self.totals;
        for slot in &self.slots {
            if let Some(task) = &slot.task {
                counters.resident += 1;
                match task.info.state {
                    TaskState::Ready => counters.ready += 1,
                    TaskState::Running => counters.running += 1,
                    TaskState::Blocked => counters.blocked += 1,
                    TaskState::Finished => counters.finished += 1,
                    TaskState::Cancelled => counters.cancelled += 1,
                }
                if task.info.state == TaskState::Running && task.info.cancel_requested {
                    counters.cancellation_pending += 1;
                }
            }
        }
        counters
    }

    pub fn hart_counters(&self, hart: usize) -> Result<HartCounters, SchedulerError> {
        let state = self.harts.get(hart).ok_or(SchedulerError::HartOutOfRange)?;
        Ok(HartCounters {
            ready: state.ready.len(),
            running: usize::from(state.running.is_some()),
            reserved_ready_slots: self.runnable_load(hart),
            dispatched_total: state.dispatched_total,
        })
    }

    fn runnable_load(&self, hart: usize) -> usize {
        self.harts[hart].ready.len() + usize::from(self.harts[hart].running.is_some())
    }

    fn choose_hart(&self, role: Role) -> Result<usize, SchedulerError> {
        let capacity = self.config.limits.queue_capacity_per_hart;
        if role == Role::Ui {
            return if self.runnable_load(self.config.ui_hart) < capacity {
                Ok(self.config.ui_hart)
            } else {
                Err(SchedulerError::ReadyCapacity)
            };
        }
        let mut best = None;
        let mut best_load = capacity;
        for offset in 0..self.worker_harts.len() {
            let hart =
                self.worker_harts[(self.placement_cursor + offset) % self.worker_harts.len()];
            let load = self.runnable_load(hart);
            if load < best_load {
                best = Some(hart);
                best_load = load;
            }
        }
        best.ok_or(SchedulerError::ReadyCapacity)
    }

    fn get_task(&self, id: TaskId) -> Result<&Task, SchedulerError> {
        if id.scheduler != self.identity {
            return Err(SchedulerError::TaskNotFound);
        }
        self.slots
            .get(id.slot)
            .and_then(|slot| slot.task.as_ref())
            .filter(|task| task.info.id == id)
            .ok_or(SchedulerError::TaskNotFound)
    }

    fn validate_dispatch(&self, dispatch: Dispatch) -> Result<usize, SchedulerError> {
        let task = self
            .get_task(dispatch.task)
            .map_err(|_| SchedulerError::StaleDispatch)?;
        if task.info.state != TaskState::Running
            || task.info.hart != dispatch.hart
            || self.harts.get(dispatch.hart).and_then(|hart| hart.running) != Some(dispatch)
        {
            return Err(SchedulerError::StaleDispatch);
        }
        Ok(dispatch.task.slot)
    }

    fn safe_point(
        &mut self,
        dispatch: Dispatch,
        state: TaskState,
        wake_at: Option<u64>,
    ) -> Result<TaskState, SchedulerError> {
        let index = self.validate_dispatch(dispatch)?;
        if self.slots[index]
            .task
            .as_ref()
            .unwrap()
            .info
            .cancel_requested
        {
            self.finish(index, TaskResult::Cancelled);
            return Ok(TaskState::Cancelled);
        }
        self.harts[dispatch.hart].running = None;
        let info = &mut self.slots[index].task.as_mut().unwrap().info;
        info.state = state;
        info.wake_at = wake_at;
        if state == TaskState::Ready {
            self.harts[dispatch.hart].ready.push_back(dispatch.task);
            self.totals.yielded_total = self.totals.yielded_total.saturating_add(1);
        } else {
            self.totals.blocked_total = self.totals.blocked_total.saturating_add(1);
        }
        Ok(state)
    }

    fn finish(&mut self, index: usize, result: TaskResult) {
        let task = self.slots[index].task.as_mut().unwrap();
        if task.info.state == TaskState::Running {
            self.harts[task.info.hart].running = None;
        }
        task.info.wake_at = None;
        match &result {
            TaskResult::Completed(bytes) => {
                task.info.state = TaskState::Finished;
                self.totals.result_bytes += bytes.len();
                self.totals.completed_total = self.totals.completed_total.saturating_add(1);
            }
            TaskResult::Cancelled => {
                task.info.state = TaskState::Cancelled;
                self.totals.cancelled_total = self.totals.cancelled_total.saturating_add(1);
            }
        }
        self.totals.job_bytes -= task.job_bytes;
        task.job_bytes = 0;
        task.job = None;
        task.result = Some(result);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scheduler(harts: usize, threads: usize, capacity: usize) -> Scheduler {
        Scheduler::new(SchedulerConfig::new(harts, threads, 0, capacity).unwrap()).unwrap()
    }

    fn worker(scheduler: &mut Scheduler) -> TaskId {
        scheduler
            .spawn(
                Role::Worker,
                Job::Sha256 {
                    bytes: vec![1, 2, 3],
                },
            )
            .unwrap()
    }

    fn check_invariants(scheduler: &Scheduler) {
        let counters = scheduler.counters();
        assert!(counters.resident <= scheduler.config.capacity);
        assert_eq!(
            counters.resident,
            counters.ready
                + counters.running
                + counters.blocked
                + counters.finished
                + counters.cancelled
        );
        assert!(counters.job_bytes <= scheduler.config.limits.max_total_job_bytes);
        assert!(counters.result_bytes <= scheduler.config.limits.max_total_result_bytes);
        let mut seen = vec![0; scheduler.config.capacity];
        let mut job_bytes = 0;
        let mut result_bytes = 0;
        for (hart_id, hart) in scheduler.harts.iter().enumerate() {
            assert!(
                scheduler.runnable_load(hart_id) <= scheduler.config.limits.queue_capacity_per_hart
            );
            for id in &hart.ready {
                seen[id.slot] += 1;
                let task = scheduler.get_task(*id).unwrap();
                assert_eq!(task.info.hart, hart_id);
                assert_eq!(task.info.state, TaskState::Ready);
            }
            if let Some(dispatch) = hart.running {
                scheduler.validate_dispatch(dispatch).unwrap();
                seen[dispatch.task.slot] += 1;
            }
        }
        for (index, slot) in scheduler.slots.iter().enumerate() {
            if let Some(task) = &slot.task {
                assert_eq!(
                    seen[index],
                    usize::from(matches!(
                        task.info.state,
                        TaskState::Ready | TaskState::Running
                    ))
                );
                if task.info.role == Role::Ui {
                    assert_eq!(task.info.hart, scheduler.config.ui_hart);
                } else if scheduler.config.hart_count > 1 {
                    assert_ne!(task.info.hart, scheduler.config.ui_hart);
                }
                job_bytes += task.job_bytes;
                if let Some(TaskResult::Completed(bytes)) = &task.result {
                    assert!(bytes.len() <= scheduler.config.limits.max_result_bytes);
                    result_bytes += bytes.len();
                }
            } else {
                assert_eq!(seen[index], 0);
            }
        }
        assert_eq!(job_bytes, counters.job_bytes);
        assert_eq!(result_bytes, counters.result_bytes);
    }

    #[test]
    fn topology_physical_cores_before_smt_and_ui_siblings() {
        for (harts, threads, expected) in [
            (1, 1, vec![0]),
            (2, 1, vec![1]),
            (2, 2, vec![1]),
            (4, 1, vec![1, 2, 3]),
            (4, 2, vec![2, 3, 1]),
            (8, 1, vec![1, 2, 3, 4, 5, 6, 7]),
            (8, 2, vec![2, 4, 6, 3, 5, 7, 1]),
            (8, 4, vec![4, 5, 6, 7, 1, 2, 3]),
        ] {
            let mut scheduler = scheduler(harts, threads, 64);
            assert_eq!(scheduler.config.worker_harts().unwrap(), expected);
            for expected_hart in expected {
                let id = worker(&mut scheduler);
                assert_eq!(scheduler.task(id).unwrap().hart, expected_hart);
                check_invariants(&scheduler);
            }
        }
        let config = SchedulerConfig::new(8, 2, 3, 32).unwrap();
        assert_eq!(config.worker_harts().unwrap(), vec![0, 4, 6, 1, 5, 7, 2]);
        assert_eq!(config.core_of(7), Ok(3));
        let mut scheduler = Scheduler::new(config).unwrap();
        let ui = scheduler.spawn(Role::Ui, Job::Ui).unwrap();
        assert_eq!(scheduler.task(ui).unwrap().hart, 3);
        let main = scheduler.spawn(Role::Main, Job::Main).unwrap();
        assert_eq!(scheduler.task(main).unwrap().hart, 0);
    }

    #[test]
    fn fifo_fairness_and_all_harts_progress_for_one_two_four_eight() {
        for harts in [1, 2, 4, 8] {
            let mut scheduler = scheduler(harts, if harts >= 4 { 2 } else { 1 }, 64);
            let mut ids = vec![scheduler.spawn(Role::Ui, Job::Ui).unwrap()];
            ids.push(scheduler.spawn(Role::Main, Job::Main).unwrap());
            for _ in 0..24 {
                ids.push(worker(&mut scheduler));
            }
            for _ in 0..104 {
                for hart in 0..harts {
                    let token = scheduler.dispatch(hart).unwrap().unwrap();
                    assert_eq!(scheduler.dispatch(hart).unwrap(), None);
                    scheduler.yield_now(token).unwrap();
                }
                check_invariants(&scheduler);
            }
            for hart in 0..harts {
                let counts: Vec<_> = ids
                    .iter()
                    .filter_map(|id| {
                        let info = scheduler.task(*id).unwrap();
                        (info.hart == hart).then_some(info.dispatches)
                    })
                    .collect();
                assert!(!counts.is_empty());
                assert!(counts.iter().all(|count| *count > 0));
                assert!(counts.iter().max().unwrap() - counts.iter().min().unwrap() <= 1);
            }
        }
    }

    #[test]
    fn single_hart_time_slices_ui_main_and_workers_in_fifo_order() {
        let mut scheduler = scheduler(1, 1, 3);
        let ids = [
            scheduler.spawn(Role::Ui, Job::Ui).unwrap(),
            scheduler.spawn(Role::Main, Job::Main).unwrap(),
            worker(&mut scheduler),
        ];
        for _ in 0..4 {
            for id in ids {
                let token = scheduler.dispatch(0).unwrap().unwrap();
                assert_eq!(token.task(), id);
                scheduler.yield_now(token).unwrap();
            }
        }
    }

    #[test]
    fn round_robin_placement_survives_serial_spawn_complete_reap() {
        let mut scheduler = scheduler(8, 2, 1);
        let expected = scheduler.config.worker_harts().unwrap();
        for round in 0..35 {
            let id = worker(&mut scheduler);
            let hart = scheduler.task(id).unwrap().hart;
            assert_eq!(hart, expected[round % expected.len()]);
            let token = scheduler.dispatch(hart).unwrap().unwrap();
            scheduler.complete(token, vec![]).unwrap();
            assert_eq!(
                scheduler.take_result(id),
                Ok(Some(TaskResult::Completed(vec![])))
            );
        }
        check_invariants(&scheduler);
    }

    #[test]
    fn dispatch_epochs_reject_duplicate_yield_block_and_complete() {
        let mut scheduler = scheduler(2, 1, 2);
        let id = worker(&mut scheduler);
        let old = scheduler.dispatch(1).unwrap().unwrap();
        scheduler.yield_now(old).unwrap();
        assert_eq!(
            scheduler.complete(old, vec![]),
            Err(SchedulerError::StaleDispatch)
        );
        let current = scheduler.dispatch(1).unwrap().unwrap();
        assert_eq!(old.task(), current.task());
        assert_ne!(old.epoch(), current.epoch());
        for stale in [
            old,
            Dispatch { hart: 0, ..current },
            Dispatch {
                epoch: 0,
                ..current
            },
        ] {
            assert_eq!(
                scheduler.yield_now(stale),
                Err(SchedulerError::StaleDispatch)
            );
            assert_eq!(scheduler.block(stale), Err(SchedulerError::StaleDispatch));
            assert_eq!(scheduler.job(stale), Err(SchedulerError::StaleDispatch));
        }
        scheduler.complete(current, vec![9]).unwrap();
        assert_eq!(
            scheduler.complete(current, vec![10]),
            Err(SchedulerError::StaleDispatch)
        );
        assert_eq!(
            scheduler.take_result(id),
            Ok(Some(TaskResult::Completed(vec![9])))
        );
        assert_eq!(scheduler.take_result(id), Err(SchedulerError::TaskNotFound));
        check_invariants(&scheduler);
    }

    #[test]
    fn generations_and_scheduler_identity_reject_recycled_and_foreign_tokens() {
        let mut first = scheduler(1, 1, 1);
        let old_id = worker(&mut first);
        let old = first.dispatch(0).unwrap().unwrap();
        first.complete(old, vec![]).unwrap();
        first.take_result(old_id).unwrap();
        let new_id = worker(&mut first);
        assert_eq!(old_id.slot(), new_id.slot());
        assert_ne!(old_id.generation(), new_id.generation());
        let new = first.dispatch(0).unwrap().unwrap();
        assert_eq!(first.cancel(old_id), Err(SchedulerError::TaskNotFound));
        assert_eq!(first.wake(old_id), Err(SchedulerError::TaskNotFound));
        assert_eq!(
            first.complete(old, vec![]),
            Err(SchedulerError::StaleDispatch)
        );
        let mut second = scheduler(1, 1, 1);
        worker(&mut second);
        let foreign = second.dispatch(0).unwrap().unwrap();
        assert_eq!(first.yield_now(foreign), Err(SchedulerError::StaleDispatch));
        assert_eq!(
            second.complete(new, vec![]),
            Err(SchedulerError::StaleDispatch)
        );
        first.complete(new, vec![]).unwrap();
        check_invariants(&first);
        check_invariants(&second);
    }

    #[test]
    fn running_cancellation_holds_hart_and_slot_until_each_safe_point() {
        for safe_point in 0..4 {
            let mut scheduler = scheduler(2, 1, 2);
            let id = worker(&mut scheduler);
            let next = worker(&mut scheduler);
            let token = scheduler.dispatch(1).unwrap().unwrap();
            assert_eq!(scheduler.cancel(id), Ok(TaskState::Running));
            assert_eq!(scheduler.cancel(id), Ok(TaskState::Running));
            assert_eq!(scheduler.take_result(id), Ok(None));
            assert_eq!(scheduler.dispatch(1), Ok(None));
            assert_eq!(scheduler.task(id).unwrap().state, TaskState::Running);
            assert_eq!(scheduler.counters().cancellation_pending, 1);
            let state = match safe_point {
                0 => scheduler.complete(token, vec![0; 16_385]),
                1 => scheduler.yield_now(token),
                2 => scheduler.block(token),
                _ => scheduler.sleep(token, 99),
            };
            assert_eq!(state, Ok(TaskState::Cancelled));
            assert_eq!(scheduler.dispatch(1).unwrap().unwrap().task(), next);
            assert_eq!(scheduler.take_result(id), Ok(Some(TaskResult::Cancelled)));
            assert_eq!(
                scheduler.complete(token, vec![]),
                Err(SchedulerError::StaleDispatch)
            );
            assert_eq!(scheduler.counters().cancelled_total, 1);
            check_invariants(&scheduler);
        }
    }

    #[test]
    fn cancelling_ready_or_blocked_never_releases_another_running_task() {
        let mut scheduler = scheduler(1, 1, 4);
        let sleeper = worker(&mut scheduler);
        let sleeping = scheduler.dispatch(0).unwrap().unwrap();
        scheduler.sleep(sleeping, 10).unwrap();
        let running = worker(&mut scheduler);
        let token = scheduler.dispatch(0).unwrap().unwrap();
        let ready = worker(&mut scheduler);
        scheduler.cancel(sleeper).unwrap();
        scheduler.cancel(ready).unwrap();
        assert_eq!(scheduler.dispatch(0), Ok(None));
        assert_eq!(scheduler.task(running).unwrap().state, TaskState::Running);
        assert_eq!(scheduler.wake(sleeper), Err(SchedulerError::InvalidState));
        assert_eq!(scheduler.advance_time(10), Ok(0));
        assert_eq!(
            scheduler.take_result(ready),
            Ok(Some(TaskResult::Cancelled))
        );
        scheduler.complete(token, vec![]).unwrap();
        check_invariants(&scheduler);
    }

    #[test]
    fn queue_admission_reserves_running_yield_slot_and_pins_ui() {
        let mut config = SchedulerConfig::new(2, 1, 0, 6).unwrap();
        config.limits.queue_capacity_per_hart = 2;
        let mut scheduler = Scheduler::new(config).unwrap();
        let a = worker(&mut scheduler);
        let token = scheduler.dispatch(1).unwrap().unwrap();
        let b = worker(&mut scheduler);
        assert_eq!(
            scheduler.spawn(Role::Worker, Job::Sha256 { bytes: vec![] }),
            Err(SchedulerError::ReadyCapacity)
        );
        scheduler.spawn(Role::Ui, Job::Ui).unwrap();
        scheduler.spawn(Role::Ui, Job::Ui).unwrap();
        assert_eq!(
            scheduler.spawn(Role::Ui, Job::Ui),
            Err(SchedulerError::ReadyCapacity)
        );
        assert_eq!(scheduler.hart_counters(1).unwrap().reserved_ready_slots, 2);
        scheduler.yield_now(token).unwrap();
        assert_eq!(scheduler.dispatch(1).unwrap().unwrap().task(), b);
        assert_eq!(scheduler.task(a).unwrap().state, TaskState::Ready);
        check_invariants(&scheduler);
    }

    #[test]
    fn sleep_wake_backpressure_is_retryable_and_never_migrates() {
        let mut config = SchedulerConfig::new(2, 1, 0, 4).unwrap();
        config.limits.queue_capacity_per_hart = 1;
        let mut scheduler = Scheduler::new(config).unwrap();
        let id = worker(&mut scheduler);
        let token = scheduler.dispatch(1).unwrap().unwrap();
        scheduler.sleep(token, 10).unwrap();
        let other = worker(&mut scheduler);
        assert_eq!(scheduler.advance_time(9), Ok(0));
        assert_eq!(scheduler.advance_time(10), Ok(0));
        assert_eq!(scheduler.wake(id), Err(SchedulerError::ReadyCapacity));
        assert_eq!(scheduler.task(id).unwrap().wake_at, Some(10));
        let running = scheduler.dispatch(1).unwrap().unwrap();
        scheduler.complete(running, vec![]).unwrap();
        assert_eq!(scheduler.advance_time(10), Ok(1));
        assert_eq!(
            scheduler.advance_time(9),
            Err(SchedulerError::ClockWentBackwards)
        );
        assert_eq!(scheduler.now(), 10);
        assert_eq!(scheduler.task(id).unwrap().hart, 1);
        let token = scheduler.dispatch(1).unwrap().unwrap();
        scheduler.sleep(token, 10).unwrap();
        assert_eq!(scheduler.task(id).unwrap().state, TaskState::Ready);
        let token = scheduler.dispatch(1).unwrap().unwrap();
        scheduler.block(token).unwrap();
        assert_eq!(scheduler.advance_time(u64::MAX), Ok(0));
        scheduler.wake(id).unwrap();
        assert_eq!(scheduler.wake(id), Err(SchedulerError::InvalidState));
        assert!(scheduler.take_result(other).unwrap().is_some());
        check_invariants(&scheduler);
    }

    #[test]
    fn descriptor_backpressure_includes_unclaimed_terminal_results() {
        let mut scheduler = scheduler(1, 1, 1);
        let id = worker(&mut scheduler);
        let token = scheduler.dispatch(0).unwrap().unwrap();
        scheduler.complete(token, vec![]).unwrap();
        assert_eq!(
            scheduler.spawn(Role::Ui, Job::Ui),
            Err(SchedulerError::TaskCapacity)
        );
        assert_eq!(scheduler.counters().job_bytes, 0);
        scheduler.take_result(id).unwrap();
        let id = worker(&mut scheduler);
        scheduler.cancel(id).unwrap();
        assert_eq!(
            scheduler.spawn(Role::Ui, Job::Ui),
            Err(SchedulerError::TaskCapacity)
        );
        scheduler.take_result(id).unwrap();
        scheduler.spawn(Role::Ui, Job::Ui).unwrap();
        check_invariants(&scheduler);
    }

    #[test]
    fn bounded_one_shot_responses_reject_without_consuming_dispatch() {
        let mut config = SchedulerConfig::new(4, 1, 0, 4).unwrap();
        config.limits.max_result_bytes = 4;
        config.limits.max_total_result_bytes = 4;
        let mut scheduler = Scheduler::new(config).unwrap();
        let a = worker(&mut scheduler);
        let b = worker(&mut scheduler);
        let first = scheduler.dispatch(1).unwrap().unwrap();
        let second = scheduler.dispatch(2).unwrap().unwrap();
        assert_eq!(
            scheduler.complete(first, vec![0; 5]),
            Err(SchedulerError::ResultBytes)
        );
        assert_eq!(scheduler.task(a).unwrap().state, TaskState::Running);
        scheduler.complete(first, vec![1; 4]).unwrap();
        assert_eq!(
            scheduler.complete(second, vec![2]),
            Err(SchedulerError::ResultCapacity)
        );
        assert_eq!(scheduler.task(b).unwrap().state, TaskState::Running);
        assert_eq!(
            scheduler.take_result(a),
            Ok(Some(TaskResult::Completed(vec![1; 4])))
        );
        scheduler.complete(second, vec![2]).unwrap();
        assert_eq!(scheduler.counters().result_bytes, 1);
        assert_eq!(
            scheduler.take_result(b),
            Ok(Some(TaskResult::Completed(vec![2])))
        );
        assert_eq!(scheduler.counters().result_bytes, 0);
        check_invariants(&scheduler);
    }

    #[test]
    fn job_payloads_names_args_roles_and_aggregate_bytes_are_bounded() {
        let mut config = SchedulerConfig::new(2, 1, 0, 8).unwrap();
        config.limits.max_job_bytes = 16;
        config.limits.max_total_job_bytes = 16;
        config.limits.max_name_bytes = 4;
        config.limits.max_wasm_args = 1;
        let mut scheduler = Scheduler::new(config).unwrap();
        assert_eq!(
            scheduler.spawn(Role::Worker, Job::Ui),
            Err(SchedulerError::InvalidRole)
        );
        assert_eq!(
            scheduler.spawn(Role::Ui, Job::Sha256 { bytes: vec![] }),
            Err(SchedulerError::InvalidRole)
        );
        for name in ["", "a\0b", "1bad", "a-b"] {
            assert_eq!(
                scheduler.spawn(
                    Role::Worker,
                    Job::HolyC {
                        handler: name.into(),
                        arg: 0
                    }
                ),
                Err(SchedulerError::InvalidName)
            );
        }
        assert_eq!(
            scheduler.spawn(
                Role::Worker,
                Job::HolyC {
                    handler: "hello".into(),
                    arg: 0
                }
            ),
            Err(SchedulerError::NameBytes)
        );
        assert_eq!(
            scheduler.spawn(
                Role::Worker,
                Job::WasmNumeric {
                    module: vec![],
                    export: "add".into(),
                    args: vec![1, 2]
                }
            ),
            Err(SchedulerError::WasmArgs)
        );
        assert_eq!(
            scheduler.spawn(Role::Worker, Job::Sha256 { bytes: vec![0; 17] }),
            Err(SchedulerError::JobBytes)
        );
        let id = scheduler
            .spawn(
                Role::Worker,
                Job::WasmNumeric {
                    module: vec![0, 97, 115, 109, 1],
                    export: "add".into(),
                    args: vec![7],
                },
            )
            .unwrap();
        assert_eq!(scheduler.counters().job_bytes, 16);
        assert_eq!(
            scheduler.spawn(Role::Worker, Job::Sha256 { bytes: vec![0] }),
            Err(SchedulerError::JobCapacity)
        );
        scheduler.cancel(id).unwrap();
        assert_eq!(scheduler.counters().job_bytes, 0);
        scheduler
            .spawn(
                Role::Main,
                Job::HolyC {
                    handler: "Init".into(),
                    arg: u64::MAX,
                },
            )
            .unwrap();
        check_invariants(&scheduler);
    }

    #[test]
    fn dispatched_job_is_owned_data_available_without_scheduler_borrow() {
        let mut scheduler = scheduler(2, 1, 2);
        let expected = Job::WasmNumeric {
            module: vec![0, 97, 115, 109],
            export: "sum".into(),
            args: vec![1, 2],
        };
        let id = scheduler.spawn(Role::Worker, expected.clone()).unwrap();
        let token = scheduler.dispatch(1).unwrap().unwrap();
        let data = scheduler.job(token).unwrap();
        scheduler.spawn(Role::Ui, Job::Ui).unwrap();
        scheduler.complete(token, vec![3]).unwrap();
        scheduler.take_result(id).unwrap();
        assert_eq!(*data, expected);
        assert_eq!(scheduler.job(token), Err(SchedulerError::StaleDispatch));
        check_invariants(&scheduler);
    }

    #[test]
    fn invalid_configs_harts_and_exhausted_tokens_are_transactional() {
        for (harts, threads, ui, capacity, error) in [
            (0, 1, 0, 1, SchedulerError::InvalidTopology),
            (2, 0, 0, 1, SchedulerError::InvalidTopology),
            (3, 2, 0, 1, SchedulerError::InvalidTopology),
            (2, 1, 2, 1, SchedulerError::InvalidTopology),
            (MAX_HARTS + 1, 1, 0, 1, SchedulerError::InvalidTopology),
            (1, 1, 0, 0, SchedulerError::InvalidCapacity),
            (1, 1, 0, MAX_TASKS + 1, SchedulerError::InvalidCapacity),
        ] {
            assert_eq!(
                SchedulerConfig::new(harts, threads, ui, capacity),
                Err(error)
            );
        }
        let mut config = SchedulerConfig::new(1, 1, 0, 1).unwrap();
        config.limits.queue_capacity_per_hart = 0;
        assert_eq!(config.validate(), Err(SchedulerError::InvalidLimits));
        let mut scheduler = scheduler(1, 1, 1);
        let id = worker(&mut scheduler);
        assert_eq!(scheduler.dispatch(1), Err(SchedulerError::HartOutOfRange));
        scheduler.epoch = u64::MAX;
        let before = scheduler.counters();
        assert_eq!(scheduler.dispatch(0), Err(SchedulerError::TokenExhausted));
        assert_eq!(scheduler.counters(), before);
        scheduler.cancel(id).unwrap();
        scheduler.take_result(id).unwrap();
        scheduler.slots[0].generation = u64::MAX;
        assert_eq!(
            scheduler.spawn(Role::Ui, Job::Ui),
            Err(SchedulerError::TaskCapacity)
        );
        check_invariants(&scheduler);
    }
}
