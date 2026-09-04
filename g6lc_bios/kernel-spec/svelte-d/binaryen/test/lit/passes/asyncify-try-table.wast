;; Asyncify must Flatten try_table instead of UNREACHABLE (Flatten.cpp /
;; Asyncify.cpp). Valued catch dests are still a follow-up; this uses
;; catch_all (no payload) so post-opt validation stays green.
;; RUN: wasm-opt %s -all --asyncify --pass-arg=asyncify-imports@env.pause -S -o - | filecheck %s

(module
  (import "env" "pause" (func $pause))
  (memory 1 2)

  ;; CHECK: (export "asyncify_get_state"
  ;; CHECK: (func $foo
  ;; CHECK:  (try_table
  (func $foo (export "foo")
    (block $catch
      (try_table (catch_all $catch)
        (call $pause)
      )
    )
  )
)
