export type ActivityScope =
  | { readonly kind: "global" }
  | { readonly kind: "following" }
  | { readonly kind: "user"; readonly userId: string };

export type ActivityCursor = string & { readonly __activityCursor: unique symbol };

export interface ActivityEnvelope<TItem> {
  /** Opaque durable resume position assigned by the backend. */
  readonly cursor: ActivityCursor;
  readonly item: TItem;
}

export interface ActivityStreamRequest {
  readonly scope: ActivityScope;
  readonly after?: ActivityCursor;
  readonly signal: AbortSignal;
}

/**
 * Transport port for a future ordered server stream. Iteration order is canonical and each
 * accepted envelope supplies the resume cursor for reconnects. No network protocol is assumed.
 */
export interface ActivityStreamTransport<TItem> {
  open(request: ActivityStreamRequest): AsyncIterable<ActivityEnvelope<TItem>>;
}
