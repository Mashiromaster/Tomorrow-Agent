/**
 * Usage extraction from a streaming Messages response.
 *
 * `observeUsage` returns a TransformStream that **re-enqueues every chunk
 * unmodified** and, as a side effect, scans the SSE frames for the two events
 * that carry token accounting:
 *
 *   message_start  → message.usage  (input, cache_creation, cache_read)
 *   message_delta  → usage          (output_tokens, cumulative)
 *
 * This is what lets the proxy log `cache_read_input_tokens` — the signal
 * IMPLEMENTATION.md R8 wants monitored — without retaining a single byte of
 * prompt or completion text. Only the numbers below are kept; the parsed JSON
 * is discarded with the frame.
 */

export interface StreamUsage {
  input_tokens?: number
  output_tokens?: number
  cache_creation_input_tokens?: number
  cache_read_input_tokens?: number
}

/** Longest `data:` line we are willing to buffer while looking for usage. */
const MAX_PENDING_LINE_BYTES = 64 * 1024

const numberOrUndefined = (value: unknown): number | undefined =>
  typeof value === 'number' && Number.isFinite(value) ? value : undefined

function mergeUsage(into: StreamUsage, from: Record<string, unknown>): void {
  const input = numberOrUndefined(from.input_tokens)
  const output = numberOrUndefined(from.output_tokens)
  const creation = numberOrUndefined(from.cache_creation_input_tokens)
  const read = numberOrUndefined(from.cache_read_input_tokens)

  if (input !== undefined) into.input_tokens = input
  if (creation !== undefined) into.cache_creation_input_tokens = creation
  if (read !== undefined) into.cache_read_input_tokens = read
  // `message_delta.usage.output_tokens` is cumulative; last value wins.
  if (output !== undefined) into.output_tokens = output
}

function scanDataLine(line: string, usage: StreamUsage): void {
  if (!line.startsWith('data:')) return
  const payload = line.slice(5).trim()
  if (payload.length === 0 || payload === '[DONE]') return

  // Cheap pre-filter: skip the content deltas, which are the overwhelming
  // majority of frames and never carry usage.
  if (!payload.includes('"usage"')) return

  let event: Record<string, unknown>
  try {
    event = JSON.parse(payload) as Record<string, unknown>
  } catch {
    return // A frame we cannot read is not a reason to disturb the stream.
  }

  if (event.type === 'message_start') {
    const message = event.message as Record<string, unknown> | undefined
    const nested = message?.usage as Record<string, unknown> | undefined
    if (nested) mergeUsage(usage, nested)
    return
  }
  if (event.type === 'message_delta') {
    const nested = event.usage as Record<string, unknown> | undefined
    if (nested) mergeUsage(usage, nested)
  }
}

/**
 * `onComplete` fires once the upstream body ends, with whatever usage was
 * seen. It is invoked for aborted streams too (with partial usage), so the
 * caller can still attribute cost.
 */
export function observeUsage(onComplete: (usage: StreamUsage) => void): TransformStream<Uint8Array, Uint8Array> {
  const usage: StreamUsage = {}
  const decoder = new TextDecoder()
  let pending = ''
  let finished = false

  const finish = () => {
    if (finished) return
    finished = true
    onComplete(usage)
  }

  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      // Forward first and unchanged — observation must never alter the stream
      // the client sees, nor delay it.
      controller.enqueue(chunk)

      pending += decoder.decode(chunk, { stream: true })
      let newlineIndex = pending.indexOf('\n')
      while (newlineIndex !== -1) {
        const line = pending.slice(0, newlineIndex).replace(/\r$/, '')
        pending = pending.slice(newlineIndex + 1)
        scanDataLine(line, usage)
        newlineIndex = pending.indexOf('\n')
      }

      // A pathologically long line (or a non-SSE body) must not grow forever.
      if (pending.length > MAX_PENDING_LINE_BYTES) pending = ''
    },
    flush() {
      pending += decoder.decode()
      if (pending.length > 0 && pending.length <= MAX_PENDING_LINE_BYTES) {
        scanDataLine(pending.replace(/\r$/, ''), usage)
      }
      finish()
    },
    cancel() {
      finish()
    },
  })
}
