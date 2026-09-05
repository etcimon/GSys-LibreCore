// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from "bun:test";
import { createComputePool } from "../src/kernel.ts";
import { executeComputeJob } from "../src/worker.ts";

const input = () => new TextEncoder().encode("abc").buffer;
const digest = () => ({ kind: "digest", algorithm: "SHA-256", data: input() });

function poolFixture(limit = 4) {
  const workers: FakeWorker[] = [];
  const timers = new Map<number, Function>();
  let timer = 0;
  class FakeWorker {
    onmessage: Function = () => {};
    onerror: Function = () => {};
    onmessageerror: Function = () => {};
    messages: any[] = [];
    terminated = false;
    constructor(public url: string, public options: any) { workers.push(this); }
    postMessage(value: unknown) { this.messages.push(value); }
    terminate() { this.terminated = true; }
    reply(data = new Uint8Array([1, 2]).buffer) { this.onmessage({ data: { id: this.messages.at(-1).id, result: { data } } }); }
  }
  const platform = {
    Worker: FakeWorker, navigator: { hardwareConcurrency: 3 }, queueMicrotask,
    setTimeout: (fn: Function) => { timers.set(++timer, fn); return timer; },
    clearTimeout: (id: number) => { timers.delete(id); },
  };
  return { workers, timers, platform, pool: createComputePool("/custom/worker.js", limit, platform) };
}

describe("dedicated compute worker protocol", () => {
  test("SHA-256 is real WebCrypto and requires an explicit supported algorithm", async () => {
    const result = await executeComputeJob(digest());
    expect(Buffer.from(result.data).toString("hex")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    await expect(executeComputeJob({ ...digest(), algorithm: "MD5" })).rejects.toHaveProperty("name", "NotSupportedError");
    await expect(executeComputeJob({ ...digest(), data: new Uint8Array(3) })).rejects.toHaveProperty("name", "DataError");
  });

  test("AES-GCM uses non-extractable keys, fresh 96-bit nonces and authenticates ciphertext", async () => {
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    const job = { kind: "encrypt", key, data: input(), additionalData: new TextEncoder().encode("context").buffer };
    const a = await executeComputeJob(job), b = await executeComputeJob(job);
    expect(a.iv!.byteLength).toBe(12);
    expect(Buffer.from(a.iv!)).not.toEqual(Buffer.from(b.iv!));
    const plain = await executeComputeJob({ ...job, ...a, kind: "decrypt" });
    expect(new TextDecoder().decode(plain.data)).toBe("abc");
    new Uint8Array(a.data)[0] ^= 1;
    await expect(executeComputeJob({ ...job, ...a, kind: "decrypt" })).rejects.toHaveProperty("name", "OperationError");
    const large = await executeComputeJob({ ...job, data: new ArrayBuffer(1048576) });
    expect(large.data.byteLength).toBe(1048592);
    expect((await executeComputeJob({ ...job, ...large, kind: "decrypt" })).data.byteLength).toBe(1048576);
    const extractable = await crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    await expect(executeComputeJob({ ...job, key: extractable })).rejects.toHaveProperty("name", "InvalidAccessError");
    await expect(executeComputeJob({ ...job, kind: "decrypt", iv: new ArrayBuffer(1) })).rejects.toHaveProperty("name", "DataError");
  });

  test("pool reserves browser capacity, copies inputs and only dispatches one job per worker", async () => {
    const { pool, workers } = poolFixture();
    const job = digest();
    const a = pool.run(job), b = pool.run(digest()).catch((error) => error), c = pool.run(digest()).catch((error) => error);
    expect(pool.stats()).toEqual({ workers: 2, active: 2, queued: 1, limit: 2 });
    expect(workers[0].url).toBe("/custom/worker.js");
    expect(workers[0].options.type).toBe("module");
    expect(workers[0].messages[0].job.data).not.toBe(job.data);
    workers[0].reply();
    expect(new Uint8Array((await a).data)).toEqual(new Uint8Array([1, 2]));
    await Promise.resolve();
    expect(workers[0].messages.length).toBe(2);
    expect(pool.stats().queued).toBe(0);
    pool.terminate();
    expect((await b).name).toBe("AbortError");
    expect((await c).name).toBe("AbortError");
    expect(workers.every((worker) => worker.terminated)).toBe(true);
    await expect(pool.run(digest())).rejects.toHaveProperty("name", "InvalidStateError");
  });

  test("abort and deadlines retire workers and discard late results", async () => {
    const { pool, workers, timers } = poolFixture(1);
    const abort = new AbortController();
    const a = pool.run(digest(), { signal: abort.signal }).catch((error) => error);
    const b = pool.run(digest()).catch((error) => error);
    abort.abort();
    expect((await a).name).toBe("AbortError");
    await Promise.resolve();
    expect(workers[0].terminated).toBe(true);
    workers[0].reply();
    expect(pool.stats().active).toBe(1);
    [...timers.values()][0]();
    expect((await b).name).toBe("TimeoutError");
    pool.terminate();
  });

  test("errors reject promises, byte budget prevents unbounded cloning and remote URLs fail", async () => {
    const { pool, workers, platform } = poolFixture(1);
    for (const url of ["https://remote/worker.js", "//remote/worker.js", "/a/../worker.js", "/\\remote/worker.js"]) {
      expect(() => createComputePool(url, 1, platform)).toThrow();
    }
    const failed = pool.run(digest()).catch((error) => error);
    workers[0].onmessageerror();
    expect((await failed).name).toBe("DataCloneError");
    const outstanding = Array.from({ length: 16 }, () => pool.run({ ...digest(), data: new ArrayBuffer(1048576) }).catch((error) => error));
    await expect(pool.run({ ...digest(), data: new ArrayBuffer(1) })).rejects.toHaveProperty("name", "QuotaExceededError");
    pool.terminate();
    expect((await Promise.all(outstanding)).every((result) => result.name === "AbortError")).toBe(true);
  });
});
