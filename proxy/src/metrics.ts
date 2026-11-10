/**
 * Metadata-only observability.
 *
 * IMPLEMENTATION.md §4.2 commits to logging token counts, latency, model, and
 * error codes — and **never** the request or response body. That promise is
 * enforced here structurally rather than by convention: `RequestMetrics` has
 * no field capable of holding prompt or completion text, and this module is
 * the only place that calls `console.*`.
 *
 * The device is identified by a truncated hash of its keyId, so logs can be
 * grouped for cost attribution without carrying a device-linkable identifier.
 */

import { sha256, toHex, utf8 } from './bytes'
import type { StreamUsage } from './sse'

export interface RequestMetrics {
  requestId: string
  route: string
  status: number
  /** Milliseconds from entering the Worker to returning response headers. */
  latencyMs: number
  /** Truncated SHA-256 of the App Attest keyId. Pseudonymous, stable. */
  device?: string
  model?: string
  stream?: boolean
  /** `proxy` for locally generated failures, `upstream` for DeepSeek's. */
  errorSource?: 'proxy' | 'upstream'
  errorType?: string
  quotaUsed?: number
  quotaLimit?: number
  usage?: StreamUsage
}

export async function deviceLabel(keyId: string): Promise<string> {
  return toHex(await sha256(utf8(keyId))).slice(0, 16)
}

export function logMetrics(metrics: RequestMetrics): void {
  // One structured line per request. Workers Logs indexes the JSON fields.
  console.log(JSON.stringify({ kind: 'pagent.request', ...metrics }))
}
