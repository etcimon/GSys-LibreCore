// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

export async function executeComputeJob(job, cryptoApi = globalThis.crypto) {
  if (!cryptoApi?.subtle) throw new DOMException("WebCrypto unavailable", "NotSupportedError");
  if (!job || !(job.data instanceof ArrayBuffer) || job.data.byteLength > (job.kind === "decrypt" ? 1048592 : 1048576)) {
    throw new DOMException("Compute input must be an ArrayBuffer of at most 1 MiB", "DataError");
  }
  if (job.kind === "digest") {
    if (job.algorithm !== "SHA-256") throw new DOMException("Unsupported digest algorithm", "NotSupportedError");
    return { data: await cryptoApi.subtle.digest("SHA-256", job.data) };
  }
  if (!["encrypt", "decrypt"].includes(job.kind)) throw new DOMException("Unsupported compute operation", "NotSupportedError");
  if (!job.key || job.key.type !== "secret" || job.key.extractable !== false || job.key.algorithm?.name !== "AES-GCM" || !Array.isArray(job.key.usages) || !job.key.usages.includes(job.kind)) {
    throw new DOMException("A non-extractable AES-GCM key with the requested usage is required", "InvalidAccessError");
  }
  if (job.additionalData !== undefined && (!(job.additionalData instanceof ArrayBuffer) || job.additionalData.byteLength > 65536)) {
    throw new DOMException("Additional data exceeds the buffer limit", "DataError");
  }
  let iv;
  if (job.kind === "encrypt") iv = cryptoApi.getRandomValues(new Uint8Array(12));
  else {
    if (!(job.iv instanceof ArrayBuffer) || job.iv.byteLength !== 12 || job.data.byteLength < 16) {
      throw new DOMException("AES-GCM requires a 96-bit nonce and authentication tag", "DataError");
    }
    iv = new Uint8Array(job.iv);
  }
  const algorithm = { name: "AES-GCM", iv, tagLength: 128, additionalData: job.additionalData };
  const data = await cryptoApi.subtle[job.kind](algorithm, job.key, job.data);
  return { data, iv: iv.buffer };
}

if (typeof WorkerGlobalScope !== "undefined" && globalThis instanceof WorkerGlobalScope) {
  let busy = false;
  globalThis.addEventListener("message", async (event) => {
    const request = event.data;
    if (!Number.isSafeInteger(request?.id) || request.id < 1) return;
    if (busy) {
      globalThis.postMessage({ id: request.id, error: { name: "QuotaExceededError", message: "Worker is busy" } });
      return;
    }
    busy = true;
    try {
      const result = await executeComputeJob(request.job);
      globalThis.postMessage({ id: request.id, result }, result.iv ? [result.data, result.iv] : [result.data]);
    } catch (error) {
      globalThis.postMessage({ id: request.id, error: { name: error?.name || "OperationError", message: "Compute operation failed" } });
    } finally { busy = false; }
  });
}
