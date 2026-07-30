export function requireModel(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError("Agent request model must be a non-empty string.");
  }
  return value.trim();
}

export function requireMessages(value) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new TypeError("Agent request messages must be a non-empty array.");
  }
  return value.map((message) => {
    if (
      message === null ||
      typeof message !== "object" ||
      !["system", "developer", "user", "assistant", "tool"].includes(message.role)
    ) {
      throw new TypeError("Every agent message must have a supported role.");
    }
    return { ...message, content: requireContent(message.content) };
  });
}

export function requireInput(value) {
  const inputs = Array.isArray(value) ? value : [value];
  if (
    inputs.length === 0 ||
    inputs.some((entry) => typeof entry !== "string" || entry.trim() === "")
  ) {
    throw new TypeError("Agent embedding input must contain non-empty text.");
  }
  return inputs;
}

export async function requestJson(fetchImplementation, provider, url, init, ErrorType) {
  let response;
  try {
    response = await fetchImplementation(url, init);
  } catch (cause) {
    throw new ErrorType(`Could not reach ${provider} at ${new URL(url).origin}.`, {
      provider,
      retryable: true,
      cause,
    });
  }
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 4_000);
    throw new ErrorType(
      `${provider} request failed with HTTP ${response.status}.`,
      {
        provider,
        status: response.status,
        retryable: response.status === 429 || response.status >= 500,
        detail,
      },
    );
  }
  try {
    return await response.json();
  } catch (cause) {
    throw new ErrorType(`${provider} returned invalid JSON.`, {
      provider,
      status: response.status,
      cause,
    });
  }
}

function requireContent(value) {
  if (typeof value === "string") {
    if (value.trim() === "") throw new TypeError("Agent message text cannot be empty.");
    return value;
  }
  if (!Array.isArray(value) || value.length === 0) {
    throw new TypeError("Agent message content must be text or content blocks.");
  }
  return value.map((block) => {
    if (block?.type === "text" && typeof block.text === "string" && block.text !== "") {
      return { type: "text", text: block.text };
    }
    if (
      block?.type === "image" &&
      typeof block.data === "string" &&
      block.data !== "" &&
      typeof block.mediaType === "string" &&
      /^image\/[a-z0-9.+-]+$/i.test(block.mediaType)
    ) {
      return {
        type: "image",
        data: block.data,
        mediaType: block.mediaType.toLowerCase(),
      };
    }
    throw new TypeError("Unsupported agent content block.");
  });
}
