/**
 * The SSE usage observer.
 *
 * This transform sits in the path of every streamed completion, so two
 * properties matter more than the parsing itself:
 *
 *   1. **It must not alter the stream.** The client's own SSE parser sees
 *      Anthropic's bytes; any rewriting here would be a bug the device could
 *      not diagnose.
 *   2. **It must survive arbitrary chunk boundaries.** Network framing splits
 *      `data:` lines wherever it likes, including mid-JSON and mid-UTF-8.
 *      A naive per-chunk `JSON.parse` would miss usage on long frames —
 *      silently, and exactly on the big requests that cost the most.
 */

import { describe, expect, it } from 'vitest'
import { observeUsage, type StreamUsage } from '../src/sse'
import { sseFrame } from './helpers'

const encoder = new TextEncoder()

/** Pipes `text` through the observer in `chunkSize`-byte pieces. */
async function run(
  text: string,
  chunkSize = text.length,
): Promise<{ output: string; usage: StreamUsage }> {
  let usage: StreamUsage = {}
  const transform = observeUsage((seen) => {
    usage = seen
  })

  const bytes = encoder.encode(text)
  const source = new ReadableStream<Uint8Array>({
    start(controller) {
      for (let offset = 0; offset < bytes.byteLength; offset += chunkSize) {
        controller.enqueue(bytes.subarray(offset, offset + chunkSize))
      }
      controller.close()
    },
  })

  const output = await new Response(source.pipeThrough(transform)).text()
  return { output, usage }
}

const MESSAGE_START = sseFrame('message_start', {
  type: 'message_start',
  message: {
    id: 'msg_1',
    model: 'claude-opus-4-8',
    usage: {
      input_tokens: 3_142,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 12_288,
      output_tokens: 1,
    },
  },
})

const TEXT_DELTA = sseFrame('content_block_delta', {
  type: 'content_block_delta',
  index: 0,
  delta: { type: 'text_delta', text: '周六下午' },
})

const MESSAGE_DELTA = sseFrame('message_delta', {
  type: 'message_delta',
  delta: { stop_reason: 'end_turn' },
  usage: { output_tokens: 2_048 },
})

const FULL_STREAM = MESSAGE_START + TEXT_DELTA + MESSAGE_DELTA + sseFrame('message_stop', {
  type: 'message_stop',
})

describe('observeUsage', () => {
  it('passes the stream through byte-for-byte', async () => {
    const { output } = await run(FULL_STREAM)
    expect(output).toBe(FULL_STREAM)
  })

  it('passes through unchanged even when chunked one byte at a time', async () => {
    // One byte per chunk also splits the multi-byte 周 / 六 characters.
    const { output } = await run(FULL_STREAM, 1)
    expect(output).toBe(FULL_STREAM)
  })

  it('reads input, cache, and output tokens from the two usage-bearing events', async () => {
    const { usage } = await run(FULL_STREAM)
    expect(usage).toEqual({
      input_tokens: 3_142,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 12_288,
      // message_delta's cumulative value wins over message_start's placeholder.
      output_tokens: 2_048,
    })
  })

  it('finds usage when frames are split across chunk boundaries', async () => {
    for (const chunkSize of [1, 7, 13, 64, 199]) {
      const { usage, output } = await run(FULL_STREAM, chunkSize)
      expect(output).toBe(FULL_STREAM)
      expect(usage.cache_read_input_tokens, `chunkSize=${chunkSize}`).toBe(12_288)
      expect(usage.output_tokens, `chunkSize=${chunkSize}`).toBe(2_048)
    }
  })

  it('tolerates CRLF line endings', async () => {
    const { usage } = await run(FULL_STREAM.replace(/\n/g, '\r\n'))
    expect(usage.cache_read_input_tokens).toBe(12_288)
  })

  it('reports partial usage when the stream ends early', async () => {
    // Connection dropped after message_start — the input cost was still paid.
    const { usage } = await run(MESSAGE_START + TEXT_DELTA)
    expect(usage.input_tokens).toBe(3_142)
    expect(usage.cache_read_input_tokens).toBe(12_288)
    expect(usage.output_tokens).toBe(1)
  })

  it('ignores a malformed frame instead of disturbing the stream', async () => {
    const corrupt = `event: message_delta\ndata: {"usage": {broken\n\n`
    const text = MESSAGE_START + corrupt + MESSAGE_DELTA
    const { output, usage } = await run(text)

    expect(output).toBe(text)
    expect(usage.output_tokens).toBe(2_048)
  })

  it('ignores a terminal [DONE] sentinel and non-usage frames', async () => {
    const text = MESSAGE_START + TEXT_DELTA + 'data: [DONE]\n\n'
    const { usage } = await run(text)
    expect(usage.input_tokens).toBe(3_142)
  })

  it('reports no usage for a body that is not SSE at all', async () => {
    const text = JSON.stringify({ hello: 'world' })
    const { output, usage } = await run(text)
    expect(output).toBe(text)
    expect(usage).toEqual({})
  })

  it('does not accumulate unbounded state on a body with no newlines', async () => {
    // A 300KB single line: the observer drops its buffer past the cap rather
        // than growing with the stream.
    const text = `data: ${'x'.repeat(300_000)}`
    const { output } = await run(text, 4_096)
    expect(output).toBe(text)
  })
})
