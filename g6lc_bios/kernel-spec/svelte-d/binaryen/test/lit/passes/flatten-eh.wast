;; Flatten must parse try_table and not UNREACHABLE / Fatal.
;; Catch dest blocks keep their result types so the implicit catch branch
;; stays well-typed (LDC 1.43 wasm-eh).
;; RUN: wasm-opt %s -all --flatten -S -o - | filecheck %s

(module
  (tag $e-i32 (param i32))

  ;; CHECK: (func $try_table_nothrow
  ;; CHECK:  (try_table
  ;; CHECK:   (catch $e-i32 $catch)
  (func $try_table_nothrow (result i32)
    (block $catch (result i32)
      (try_table (catch $e-i32 $catch)
        (return (i32.const 1))
      )
      (unreachable)
    )
  )

  ;; CHECK: (func $try_table_throw
  ;; CHECK:  (try_table
  ;; CHECK:   (catch $e-i32 $catch)
  (func $try_table_throw (result i32)
    (block $catch (result i32)
      (try_table (catch $e-i32 $catch)
        (throw $e-i32 (i32.const 7))
      )
      (unreachable)
    )
  )

  ;; CHECK: (func $try_table_catch_all_ref
  ;; CHECK:  (try_table
  ;; CHECK:   (catch_all_ref $catch)
  (func $try_table_catch_all_ref
    (drop
      (block $catch (result (ref exn))
        (try_table (catch_all_ref $catch)
          (nop)
        )
        (unreachable)
      )
    )
  )
)
