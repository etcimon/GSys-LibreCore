// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// JS-side await flag after env.libwasm_await__void rewinds. Do not wrap
// `.await` in try/catch — landing-pad state is not part of Asyncify.
// After rewind, same-function code may read these and throw/catch.
// `{:catch e}` is filled from libwasmAwaitError() — Svelte visibility,
// not a D exception across the import.
module await_status;

nothrow:
@safe:

extern (C) @trusted int libwasm_await_supported();
extern (C) @trusted int libwasm_await_failed();
extern (C) @trusted void libwasm_note_await_fail(int handle);
extern (C) @trusted void libwasm_note_await_ok(int handle);
extern (C) @trusted string libwasm_await_error();
extern (C) @trusted string libwasm_await_value();

/// True when the ship module exported asyncify_get_state (fork wasm-opt).
@trusted bool libwasmAwaitSupported()
{
  return libwasm_await_supported() != 0;
}

/// True when the last `.await` rejected. Valid only after rewind.
@trusted bool libwasmAwaitFailed()
{
  return libwasm_await_failed() != 0;
}

/// Record a JsPromise.error reason so libwasmAwaitError() can read it.
/// The stock (non-asyncify) path never goes through libwasm_await__void.
@trusted void libwasmNoteAwaitFail(int handle)
{
  libwasm_note_await_fail(handle);
}

/// Reject reason after rewind or after libwasmNoteAwaitFail.
/// Empty when the last await resolved or nothing was recorded.
@trusted string libwasmAwaitError()
{
  return libwasm_await_error();
}

/// Record a JsPromise.then value so libwasmAwaitValue() can read it.
/// The stock (non-asyncify) path never goes through libwasm_await__void.
@trusted void libwasmNoteAwaitOk(int handle)
{
  libwasm_note_await_ok(handle);
}

/// Resolve value after rewind or after libwasmNoteAwaitOk.
/// Empty when the last await rejected or nothing was recorded.
@trusted string libwasmAwaitValue()
{
  return libwasm_await_value();
}
