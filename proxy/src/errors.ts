/**
 * Proxy-originated errors reuse the Anthropic error envelope verbatim:
 *
 *   { "type": "error", "error": { "type": ..., "message": ... }, "request_id": ... }
 *
 * so the iOS client has exactly one error shape to decode regardless of whether
 * the failure happened at the proxy or upstream. The `x-pagent-error-source`
 * header distinguishes the two when the client needs to (e.g. "re-attest the
 * device" is only ever a proxy-side instruction).
 */

/**
 * Error types we emit.
 *
 * The Anthropic vocabulary, because the client decodes one envelope shape for
 * both proxy-side and upstream failures and DeepSeek's compatible endpoint
 * returns the same shape.
 */
export type AnthropicErrorType =
  | 'invalid_request_error'
  | 'authentication_error'
  | 'permission_error'
  | 'not_found_error'
  | 'request_too_large'
  | 'rate_limit_error'
  | 'api_error'
  | 'overloaded_error'

export interface ProxyErrorBody {
  type: 'error'
  error: { type: AnthropicErrorType; message: string }
  request_id: string | null
}

export class ProxyError extends Error {
  constructor(
    readonly status: number,
    readonly errorType: AnthropicErrorType,
    message: string,
    /** Extra response headers, e.g. `retry-after` on a 429. */
    readonly headers: Record<string, string> = {},
  ) {
    super(message)
    this.name = 'ProxyError'
  }

  toResponse(requestId: string): Response {
    const body: ProxyErrorBody = {
      type: 'error',
      error: { type: this.errorType, message: this.message },
      request_id: requestId,
    }
    return new Response(JSON.stringify(body), {
      status: this.status,
      headers: {
        'content-type': 'application/json',
        'x-pagent-error-source': 'proxy',
        'x-pagent-request-id': requestId,
        ...this.headers,
      },
    })
  }
}

export const badRequest = (m: string) => new ProxyError(400, 'invalid_request_error', m)
export const unauthorized = (m: string) => new ProxyError(401, 'authentication_error', m)
export const forbidden = (m: string) => new ProxyError(403, 'permission_error', m)
export const tooLarge = (m: string) => new ProxyError(413, 'request_too_large', m)

export function rateLimited(m: string, retryAfterSeconds: number): ProxyError {
  return new ProxyError(429, 'rate_limit_error', m, {
    'retry-after': String(Math.max(1, Math.ceil(retryAfterSeconds))),
  })
}

export const upstreamUnavailable = (m: string) => new ProxyError(502, 'api_error', m)
