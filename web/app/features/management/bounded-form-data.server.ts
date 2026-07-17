export class RequestBodyTooLargeError extends RangeError {
  public constructor(public readonly maxBytes: number) {
    super(`The request body exceeds ${maxBytes} bytes.`);
    this.name = "RequestBodyTooLargeError";
  }
}

/**
 * Parses a form while enforcing the byte ceiling as the request stream is consumed.
 * The Content-Length check is only an early rejection; the stream counter remains
 * authoritative for chunked requests and clients that omit the header.
 */
export async function readBoundedFormData(request: Request, maxBytes: number): Promise<FormData> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) {
    throw new RangeError("maxBytes must be a positive safe integer.");
  }

  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength !== null && /^\d+$/.test(declaredLength)) {
    const declaredBytes = Number(declaredLength);
    if (!Number.isSafeInteger(declaredBytes) || declaredBytes > maxBytes) {
      throw new RequestBodyTooLargeError(maxBytes);
    }
  }

  if (request.body === null) return request.formData();

  let receivedBytes = 0;
  let exceeded = false;
  const boundedBody = request.body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        receivedBytes += chunk.byteLength;
        if (receivedBytes > maxBytes) {
          exceeded = true;
          controller.error(new RequestBodyTooLargeError(maxBytes));
          return;
        }
        controller.enqueue(chunk);
      },
    }),
  );
  const contentType = request.headers.get("Content-Type");
  const headers = contentType === null ? undefined : { "Content-Type": contentType };
  try {
    return await new Response(boundedBody, { headers }).formData();
  } catch (error) {
    // Node's multipart parser may wrap a stream error. Preserve a stable error
    // type for the route boundary whenever our counter was the cause.
    if (exceeded) throw new RequestBodyTooLargeError(maxBytes);
    throw error;
  }
}
