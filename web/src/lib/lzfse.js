let decoderPromise;

const archiveMagic = new Uint8Array([0x45, 0x53, 0x42, 0x43, 0x30, 0x30, 0x30, 0x31]);
const archiveHeaderSize = 16;
const maximumUncompressedBytes = 512 * 1024 * 1024;

function aligned(value, alignment = 16) {
  return (value + alignment - 1) & ~(alignment - 1);
}

async function loadDecoder() {
  if (!decoderPromise) {
    const wasmURL = new URL(`${import.meta.env.BASE_URL || "/"}lzfse.wasm`, window.location.origin);
    decoderPromise = fetch(wasmURL)
      .then((response) => {
        if (!response.ok) throw new Error(`LZFSE 解码器加载失败（${response.status}）。`);
        return response.arrayBuffer();
      })
      .then((bytes) => WebAssembly.instantiate(bytes, {}));
  }
  return decoderPromise;
}

function ensureMemory(memory, requiredBytes) {
  const currentBytes = memory.buffer.byteLength;
  if (requiredBytes <= currentBytes) return;
  const pageSize = 64 * 1024;
  const pages = Math.ceil((requiredBytes - currentBytes) / pageSize);
  memory.grow(pages);
}

async function decodeLZFSE(compressed, outputSize) {
  const { instance } = await loadDecoder();
  const memory = instance.exports.memory;
  const heapBase = Number(instance.exports.__heap_base?.value ?? 131072);
  const sourceOffset = aligned(heapBase + 64 * 1024);
  const destinationOffset = aligned(sourceOffset + compressed.byteLength + 16);
  ensureMemory(memory, destinationOffset + outputSize + 16);

  new Uint8Array(memory.buffer, sourceOffset, compressed.byteLength).set(compressed);
  const decodedSize = Number(instance.exports.decode(
    destinationOffset,
    outputSize,
    sourceOffset,
    compressed.byteLength,
  ));
  if (decodedSize !== outputSize) {
    throw new Error(`LZFSE 解码长度不一致（期望 ${outputSize}，得到 ${decodedSize}）。`);
  }
  return new Uint8Array(memory.buffer.slice(destinationOffset, destinationOffset + decodedSize));
}

function readBigEndianUint64(bytes, offset) {
  let value = 0;
  for (let index = 0; index < 8; index += 1) value = value * 256 + bytes[offset + index];
  return value;
}

function hasMagic(bytes) {
  return archiveMagic.every((value, index) => bytes[index] === value);
}

export async function decodeCompactCheckpoint(blob) {
  const archive = new Uint8Array(await blob.arrayBuffer());
  if (archive.byteLength <= archiveHeaderSize || !hasMagic(archive)) {
    throw new Error("紧凑基线文件头无效。");
  }
  const uncompressedSize = readBigEndianUint64(archive, archiveMagic.length);
  if (!Number.isSafeInteger(uncompressedSize) || uncompressedSize <= 0 || uncompressedSize > maximumUncompressedBytes) {
    throw new Error("紧凑基线原始大小无效。");
  }
  const clear = await decodeLZFSE(archive.subarray(archiveHeaderSize), uncompressedSize);
  return JSON.parse(new TextDecoder().decode(clear));
}
