# fixtures

Package-local cosim goldens live as **code** in `crates/ai-tensor-rt/src/cosim.rs`
(`builtin_goldens`) so `cargo test` stays self-contained.

Optional external harness:

```bash
export AI_TENSOR_COSIM_CMD='echo pong'
cargo run -p ai-tensor-cli -- golden-check
```

Monorepo spawn (does not link RTL into crates):

```bash
bash monorepo-soak/run-ai-tensor.sh test
```
