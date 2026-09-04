;; Valued catch dest (LDC 1.43 landing-pad shape).
;; RUN: wasm-opt %s -all --asyncify --optimize-level=0 --pass-arg=asyncify-imports@env.pause -S -o - | filecheck %s

(module
  (import "env" "pause" (func $pause))
  (tag $e (param i32))
  (memory 1 2)

  ;; CHECK: (export "asyncify_get_state"
  ;; CHECK: (func $foo
  ;; CHECK:  (try_table
  (func $foo (export "foo") (result i32)
    (block $catch (result i32)
      (try_table (catch $e $catch)
        (call $pause)
        (return (i32.const 0))
      )
      (unreachable)
    )
  )
)
