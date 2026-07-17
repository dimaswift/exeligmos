import { describe, expect, it } from "vitest";

import { readBoundedFormData, RequestBodyTooLargeError } from "./bounded-form-data.server";

describe("readBoundedFormData", () => {
  it("parses a multipart stream below the ceiling without relying on Content-Length", async () => {
    const input = new FormData();
    input.set("intent", "create");
    input.set("attachments", new File(["hello"], "note.txt", { type: "text/plain" }));
    const request = new Request("https://web.example.test/records", {
      body: input,
      method: "POST",
    });
    expect(request.headers.has("Content-Length")).toBe(false);

    const parsed = await readBoundedFormData(request, 2_048);

    expect(parsed.get("intent")).toBe("create");
    const attachment = parsed.get("attachments");
    expect(attachment).toBeInstanceOf(File);
    expect((attachment as File).name).toBe("note.txt");
  });

  it("stops a chunked or lengthless body while it crosses the ceiling", async () => {
    const input = new FormData();
    input.set("attachments", new File(["x".repeat(512)], "large.txt"));
    const request = new Request("https://web.example.test/records", {
      body: input,
      method: "POST",
    });

    await expect(readBoundedFormData(request, 128)).rejects.toBeInstanceOf(
      RequestBodyTooLargeError,
    );
  });

  it("rejects an oversized declared length before consuming the body", async () => {
    const request = new Request("https://web.example.test/records", {
      body: "intent=create",
      headers: {
        "Content-Length": "1025",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      method: "POST",
    });

    await expect(readBoundedFormData(request, 1_024)).rejects.toBeInstanceOf(
      RequestBodyTooLargeError,
    );
  });
});
